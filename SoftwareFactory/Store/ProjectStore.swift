import AppKit
import Observation
import os

/// Every project on the board, kept in one JSON file. Reports, hooks and discovery all land here,
/// on the main actor, and the views follow along.
@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()

    private(set) var projects: [String: Project] = [:]
    /// The board's clock: ticks every 20 seconds so relative times and stale sessions move on.
    private(set) var now = Date.now
    var serverStatus: ServerStatus = .starting
    /// The API's port on 127.0.0.1.
    var port: UInt16 = API.defaultPort
    /// Whether other Macs on the network may report, with `accessToken`. Off unless turned on in Settings.
    var acceptsOtherMacs = UserDefaults.standard.bool(forKey: "FactoryAcceptsOtherMacs") {
        didSet { UserDefaults.standard.set(acceptsOtherMacs, forKey: "FactoryAcceptsOtherMacs") }
    }
    /// What other Macs send: "Authorization: Bearer …".
    private(set) var accessToken = ProjectStore.loadToken()
    /// Other Macs, and when each last reported.
    private(set) var machines: [String: Date] = [:]
    /// Claude Desktop's Code chats on this Mac, newest first, and by the Claude Code session id they run.
    private(set) var desktopChats: [DesktopChats.Chat] = []
    private(set) var chatsBySession: [String: DesktopChats.Chat] = [:]
    @ObservationIgnored private var chatRefresh: Task<Void, Never>?
    /// How often each session has been looked for among the chats: Terminal sessions never turn up.
    @ObservationIgnored var chatLookups: [String: Int] = [:]
    private(set) var isDiscovering = false
    private(set) var lastDiscovery: Date?

    @ObservationIgnored let dataDirectory: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.darrell.softwarefactory", category: "store")

    enum ServerStatus: Equatable {
        case starting
        case listening(UInt16)
        case failed(String)
    }

    init(dataDirectory: URL = ProjectStore.defaultDirectory) {
        self.dataDirectory = dataDirectory
        load()
    }

    nonisolated static var defaultDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: "FactoryDataDir") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "Software Factory", directoryHint: .isDirectory)
    }

    private var fileURL: URL { dataDirectory.appending(path: "projects.json") }

    func startClock() {
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.now = .now
                self?.refreshBadge()
            }
        }
    }

    // MARK: - Other Macs

    private static func loadToken() -> String {
        if let saved = UserDefaults.standard.string(forKey: "FactoryAccessToken"), saved.count >= 24 { return saved }
        let token = makeToken()
        UserDefaults.standard.set(token, forKey: "FactoryAccessToken")
        return token
    }

    private static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }

    /// A new token; Macs set up with the old one need setting up again.
    func replaceToken() {
        accessToken = Self.makeToken()
        UserDefaults.standard.set(accessToken, forKey: "FactoryAccessToken")
    }

    func heard(from machine: String) {
        machines[machine] = .now
        scheduleSave()
    }

    // MARK: - Reading

    /// Everything not hidden, what needs you first, then by most recent sign of life.
    var board: [Project] {
        projects.values
            .filter { !$0.hidden }
            .sorted { a, b in
                let (sa, sb) = (a.state(at: now), b.state(at: now))
                if sa.isLive != sb.isLive { return sa.isLive }
                if sa.isLive, sa.rank != sb.rank { return sa.rank < sb.rank }
                return a.lastActivity > b.lastActivity
            }
    }

    var live: [Project] { board.filter { $0.state(at: now).isLive } }
    var resting: [Project] { board.filter { !$0.state(at: now).isLive } }
    var hiddenProjects: [Project] { projects.values.filter(\.hidden).sorted { $0.name < $1.name } }

    func count(_ state: ProjectState) -> Int {
        projects.values.filter { !$0.hidden && $0.state(at: now) == state }.count
    }

    /// Projects with any sign of life since the start of today.
    var activeToday: Int {
        let start = Calendar.current.startOfDay(for: now)
        return projects.values.filter { !$0.hidden && $0.lastActivity >= start }.count
    }

    /// Every project's timeline, merged, newest first.
    func feed(limit: Int = 300) -> [(project: Project, event: Event)] {
        projects.values
            .filter { !$0.hidden }
            .flatMap { project in project.events.map { (project: project, event: $0) } }
            .sorted { $0.event.date > $1.event.date }
            .prefix(limit)
            .map { $0 }
    }

    subscript(id: String) -> Project? { projects[id] }

    /// A project by id, name or code.
    func find(_ key: String) -> Project? {
        if let exact = projects[key] { return exact }
        let lower = key.lowercased()
        return projects[Slug.make(key)]
            ?? projects.values.first { $0.name.lowercased() == lower }
            ?? projects.values.first { $0.code.lowercased() == lower }
    }

    // MARK: - Writing

    /// A folder's project root. Another Mac's folders can't be looked at from here, so its worktrees
    /// fold into their repository by name alone.
    private func root(for path: String, machine: String?) -> String {
        machine == nil ? ProjectPath.root(for: path) : ProjectPath.withoutWorktree(path)
    }

    /// The project a folder belongs to, made if it's new. A folder on another Mac (`machine`) that
    /// isn't at the same path as here matches a project by its folder's name: the same repository,
    /// checked out on both Macs.
    func projectID(forPath raw: String, create: Bool, machine: String? = nil) -> String? {
        let root = root(for: raw, machine: machine)
        guard ProjectPath.isProject(root) else { return nil }
        let match = projects.values
            .filter { project in
                guard let path = project.path else { return false }
                return root == path || root.hasPrefix(path + "/")
            }
            .max { ($0.path?.count ?? 0) < ($1.path?.count ?? 0) }
        if let match { return match.id }
        let name = (root as NSString).lastPathComponent
        if machine != nil, let same = projects.values.first(where: { project in
            ((project.path as NSString?)?.lastPathComponent ?? project.name).caseInsensitiveCompare(name) == .orderedSame
        }) {
            return same.id
        }
        guard create else { return nil }
        let project = Project(id: uniqueID(for: name), name: name, path: root, now: now)
        projects[project.id] = project
        scheduleSave()
        return project.id
    }

    private func uniqueID(for name: String) -> String {
        let base = Slug.make(name)
        var id = base
        var n = 2
        while projects[id] != nil {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// Changes one project in place and saves.
    @discardableResult
    func update(_ id: String, _ change: (inout Project) -> Void) -> Project? {
        guard var project = projects[id] else { return nil }
        change(&project)
        projects[id] = project
        scheduleSave()
        refreshBadge()
        return project
    }

    /// Applies a report. `explicitID` comes from the URL (`POST /api/projects/{id}`).
    @discardableResult
    func apply(_ report: Report, to explicitID: String? = nil, machine: String? = nil) throws -> Project {
        let state = try report.state.map { raw in
            guard let s = ProjectState(api: raw) else { throw ReportError.badState(raw) }
            return s
        }
        let kind = try report.kind.map { raw in
            guard let k = Kind(api: raw) else { throw ReportError.badKind(raw) }
            return k
        }
        let id = try resolve(report, explicitID: explicitID, machine: machine)
        let now = Date.now
        self.now = now

        return update(id) { p in
            let earlier = Set(p.events.map(\.id))
            defer {
                // What this report logged came from that Mac.
                for index in p.events.indices where !earlier.contains(p.events[index].id) { p.events[index].machine = machine }
            }
            let oldName = p.name
            if let name = report.name?.trimmed { p.name = name }
            if let code = report.code?.trimmed {
                p.code = String(code.uppercased().prefix(4))
            } else if p.name != oldName, p.code == ProjectCode.make(from: oldName) {
                p.code = ProjectCode.make(from: p.name)
            }
            if let path = report.path ?? report.cwd, p.path == nil { p.path = root(for: path, machine: machine) }
            if let summary = report.summary?.trimmed { p.summary = summary }
            if let kind { p.kind = kind }
            if let symbol = report.symbol?.trimmed { p.symbol = symbol }
            if let version = report.version?.trimmed { p.version = version }
            if let branch = report.branch?.trimmed { p.branch = branch }
            if let repo = report.repo?.trimmed { p.repo = repo }
            if let links = report.links { p.links.merge(links) { $1 } }
            if let hidden = report.hidden { p.hidden = hidden }

            if let milestone = report.milestone?.trimmed, milestone != p.milestone {
                p.milestone = milestone
                p.log(Event(date: now, symbol: "flag.fill", title: milestone, detail: "New milestone"))
            }
            if let progress = report.progress { p.progress = progress.fraction }
            if let inputs = report.steps {
                let steps = inputs.map(\.step).filter { !$0.title.isEmpty }
                let wasDone = Set(p.steps.filter { $0.status == .done }.map(\.title))
                let newlyDone = steps.filter { $0.status == .done && !wasDone.contains($0.title) }
                // Only a list that grew from an earlier one counts its ticks; a fresh list just appears.
                if !p.steps.isEmpty {
                    for step in newlyDone.prefix(3) {
                        p.log(Event(date: now, state: .done, symbol: "checkmark", title: step.title, detail: "Step done"))
                    }
                }
                p.steps = steps
            }
            let oldTask = p.task
            if let task = report.task?.trimmed { p.task = task }
            if let note = report.note?.trimmed { p.note = note }

            if let state, state != p.reported || p.task != oldTask {
                // The words lead; the state is the line under them.
                let note = report.note?.trimmed
                let title = state == .working ? (p.task ?? note ?? state.label) : (note ?? state.label)
                let detail = state == .working ? (p.task == nil ? nil : note) : (note == nil ? p.task : state.label)
                p.log(Event(date: now, state: state, symbol: state.symbol, title: title, detail: detail))
            } else if let note = report.note?.trimmed {
                p.log(Event(date: now, symbol: "text.bubble.fill", title: note))
            }
            if let state {
                if state != p.reported { p.reportedAt = now }
                p.reported = state
            }

            for field in report.clear ?? [] {
                switch field.lowercased() {
                case "task": p.task = nil
                case "note": p.note = nil
                case "milestone": p.milestone = nil
                case "progress": p.progress = nil
                case "steps": p.steps = []
                case "summary": p.summary = nil
                case "version": p.version = nil
                default: break
                }
            }
            p.lastActivity = max(p.lastActivity, now)
        }!
    }

    private func resolve(_ report: Report, explicitID: String?, machine: String?) throws -> String {
        let path = report.path ?? report.cwd
        if let explicitID {
            if let found = find(explicitID) { return found.id }
            if let path, let id = projectID(forPath: path, create: false, machine: machine) { return id }
            return create(named: report.name ?? explicitID, id: Slug.make(explicitID), path: path, machine: machine)
        }
        if let key = report.project?.trimmed {
            if let found = find(key) { return found.id }
            if path == nil { return create(named: report.name ?? key, id: Slug.make(key), path: nil, machine: machine) }
        }
        if let path, let id = projectID(forPath: path, create: true, machine: machine) { return id }
        throw ReportError.noProject
    }

    private func create(named name: String, id: String, path: String?, machine: String?) -> String {
        let id = projects[id] == nil ? id : uniqueID(for: name)
        let project = Project(id: id, name: name, path: path.map { root(for: $0, machine: machine) }, now: now)
        projects[id] = project
        return id
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        update(id) { $0.hidden = hidden }
    }

    /// Forgets a project for good. Discovery brings it back if Claude Code still has sessions there,
    /// so the board hides projects instead.
    func remove(_ id: String) {
        projects[id] = nil
        scheduleSave()
    }

    // MARK: - Claude Desktop chats

    /// Reads Claude Desktop's chats again, after `delay`: a new session's chat file can land a moment
    /// after its first hook.
    func refreshDesktopChats(after delay: Duration = .zero) {
        chatRefresh?.cancel()
        chatRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let chats = await Task.detached(priority: .utility) { DesktopChats.scan() }.value
                .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            self?.desktopChats = chats
            self?.chatsBySession = Dictionary(chats.compactMap { chat in chat.cliSessionID.map { ($0, chat) } }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The Claude Desktop chat a session runs in, if it's on this Mac and in the desktop app.
    func chat(for session: Session) -> DesktopChats.Chat? {
        session.machine == nil ? chatsBySession[session.id] : nil
    }

    /// The project's Claude Desktop chats on this Mac, worktrees included, newest first.
    func chats(for project: Project) -> [DesktopChats.Chat] {
        guard let path = project.path, project.isOnThisMac else { return [] }
        return desktopChats.filter { chat in
            guard let cwd = chat.cwd else { return false }
            let root = ProjectPath.withoutWorktree(cwd)
            return root == path || root.hasPrefix(path + "/")
        }
    }

    /// The chat a project's live session runs in, if that session is a Claude Desktop chat.
    func liveChat(for project: Project) -> DesktopChats.Chat? {
        project.liveSessions(at: now).lazy.compactMap(chat(for:)).first
    }

    /// The chat to open for a project: its live session's, else its latest session's, else its latest chat.
    func bestChat(for project: Project) -> DesktopChats.Chat? {
        let sessions = project.liveSessions(at: now) + project.sessions.sorted { $0.updated > $1.updated }
        if let chat = sessions.lazy.compactMap(chat(for:)).first { return chat }
        let chats = chats(for: project)
        return chats.first { !$0.isArchived } ?? chats.first
    }

    // MARK: - Discovery

    func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        refreshDesktopChats()
        Task {
            let found = await Discovery.scan()
            merge(found)
            isDiscovering = false
            lastDiscovery = .now
        }
    }

    private func merge(_ found: [Discovery.Found]) {
        for item in found {
            guard let id = projectID(forPath: item.root, create: true) else { continue }
            update(id) { p in
                let isNew = p.events.isEmpty && p.lastCommit == nil && p.reported == .idle && p.sessions.isEmpty
                if isNew, let activity = item.lastActivity {
                    // New to the board: its time is its last session's, not today.
                    p.lastActivity = activity
                    p.reportedAt = activity
                } else if let activity = item.lastActivity {
                    p.lastActivity = max(p.lastActivity, activity)
                }
                p.detectedKind = item.kind
                if let readme = item.readme { p.readme = readme }
                if let branch = item.branch { p.branch = branch }
                if p.repo == nil { p.repo = item.repo }
                let known = Set(p.events.compactMap(\.ref))
                var added = false
                for commit in item.commits where !known.contains(commit.hash) {
                    p.events.append(Event(date: commit.date, symbol: "chevron.left.forwardslash.chevron.right", title: commit.subject,
                                          detail: "Commit \(commit.hash.prefix(7))", ref: commit.hash))
                    added = true
                }
                if added {
                    p.events.sort { $0.date > $1.date }
                    if p.events.count > 200 { p.events.removeLast(p.events.count - 200) }
                }
                if let commit = item.commits.first {
                    p.lastCommit = commit
                    p.lastActivity = max(p.lastActivity, commit.date)
                }
                // Sessions nobody has heard from in three days are gone.
                p.sessions.removeAll { now.timeIntervalSince($0.updated) > 3 * 24 * 3600 }
            }
        }
    }

    /// The Dock icon counts the projects waiting on you.
    func refreshBadge() {
        let waiting = count(.waiting)
        let label = waiting > 0 ? "\(waiting)" : nil
        if NSApplication.shared.dockTile.badgeLabel != label { NSApplication.shared.dockTile.badgeLabel = label }
    }

    // MARK: - Saving

    private struct Saved: Codable {
        var version = 1
        var projects: [Project]
        var machines: [String: Date]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let saved = try Self.decoder.decode(Saved.self, from: data)
            projects = Dictionary(saved.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            machines = saved.machines ?? [:]
            // Earlier versions took the app's notes for tasks ("Linked sessions now…"): drop them.
            for id in Array(projects.keys) {
                projects[id]?.events.removeAll { HookText.isAppNote($0.title) }
                for index in projects[id]?.sessions.indices ?? 0..<0 where HookText.isAppNote(projects[id]?.sessions[index].task ?? "") {
                    projects[id]?.sessions[index].task = nil
                }
            }
        } catch {
            log.error("Couldn't read the board: \(error.localizedDescription, privacy: .public)")
            // Keep the unreadable file beside the new one rather than overwrite it.
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.deletingPathExtension().appendingPathExtension("unreadable.json"))
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(Saved(projects: projects.values.sorted { $0.id < $1.id }, machines: machines))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save the board: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension String {
    /// Trimmed, or nil if nothing's left.
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
