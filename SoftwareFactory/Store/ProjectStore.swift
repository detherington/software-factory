import AppKit
import Observation
import os

/// Every project on the board, kept in one JSON file. Reports, hooks and discovery all land here,
/// on the main actor, and the views follow along.
@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()

    /// Every project on the board: this Mac's own, with the other Macs' boards merged in.
    private(set) var projects: [String: Project] = [:]
    /// This Mac's own projects: what its hooks, reports and discovery say. Saved here, and shared with
    /// the other Macs through iCloud Drive.
    @ObservationIgnored private(set) var local: [String: Project] = [:]
    /// The other Macs' boards, by machine id, from iCloud Drive.
    private(set) var peers: [String: SyncFolder.Board] = [:]
    @ObservationIgnored private var peerDates: [String: Date] = [:]
    @ObservationIgnored private var syncLoop: Task<Void, Never>?
    @ObservationIgnored private var syncWrite: Task<Void, Never>?
    @ObservationIgnored private var lastSyncWrite = Date.distantPast
    /// Whether this board is shared with the other Macs' through iCloud Drive.
    var syncsWithOtherMacs = UserDefaults.standard.bool(forKey: "FactorySyncsWithOtherMacs") {
        didSet {
            UserDefaults.standard.set(syncsWithOtherMacs, forKey: "FactorySyncsWithOtherMacs")
            syncsWithOtherMacs ? startSync() : stopSync()
        }
    }
    /// This Mac's name on the other Macs' boards.
    var machineName = UserDefaults.standard.string(forKey: "FactoryMachineName") ?? Host.current().localizedName ?? "Mac" {
        didSet {
            UserDefaults.standard.set(machineName, forKey: "FactoryMachineName")
            scheduleSyncWrite()
        }
    }
    /// This Mac's board file in iCloud Drive is named for it.
    @ObservationIgnored let machineID = ProjectStore.loadMachineID()
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
                self?.checkStoppedSessions()
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
        let match = local.values
            .filter { project in
                guard let path = project.path else { return false }
                return root == path || root.hasPrefix(path + "/")
            }
            .max { ($0.path?.count ?? 0) < ($1.path?.count ?? 0) }
        if let match { return match.id }
        let name = (root as NSString).lastPathComponent
        if machine != nil, let same = local.values.first(where: { project in
            ((project.path as NSString?)?.lastPathComponent ?? project.name).caseInsensitiveCompare(name) == .orderedSame
        }) {
            return same.id
        }
        guard create else { return nil }
        let project = Project(id: uniqueID(for: name), name: name, path: root, now: now)
        local[project.id] = project
        scheduleSave()
        rebuild()
        return project.id
    }

    private func uniqueID(for name: String) -> String {
        let base = Slug.make(name)
        var id = base
        var n = 2
        while local[id] != nil {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// Changes one project in place and saves.
    @discardableResult
    func update(_ id: String, _ change: (inout Project) -> Void) -> Project? {
        guard var project = local[id] ?? localCopy(of: id) else { return nil }
        change(&project)
        local[id] = project
        scheduleSave()
        rebuild()
        refreshBadge()
        return projects[id]
    }

    /// A project that so far is only on another Mac's board, made this Mac's too so it can change
    /// here: its name and where it is, without the other Mac's sessions or timeline.
    private func localCopy(of id: String) -> Project? {
        guard let theirs = projects[id] else { return nil }
        var copy = Project(id: id, name: theirs.name, path: theirs.path, now: now)
        copy.code = theirs.code
        copy.kind = theirs.kind
        copy.repo = theirs.repo
        copy.lastActivity = theirs.lastActivity
        copy.reportedAt = theirs.reportedAt
        return copy
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
                p.stepsUpdated = now
            }
            if report.advance == true {
                if let step = Step.advance(&p.steps) {
                    p.log(Event(date: now, state: .done, symbol: "checkmark", title: step.title, detail: "Step done"))
                }
                p.stepsUpdated = now
            }
            let oldTask = p.task
            if let task = report.task?.trimmed { p.task = task }
            if let note = report.note?.trimmed { p.note = note }

            if let state, state != p.reported || p.task != oldTask || state == .done {
                // The words lead; the state is the line under them.
                let note = report.note?.trimmed
                let title = state == .working ? (p.task ?? note ?? state.label) : (note ?? state.label)
                let detail = state == .working ? (p.task == nil ? nil : note) : (note == nil ? p.task : state.label)
                p.log(Event(date: now, state: state, symbol: state.symbol, title: title, detail: detail))
            } else if let note = report.note?.trimmed {
                p.log(Event(date: now, symbol: "text.bubble.fill", title: note))
            }
            if let state {
                // Each release is news, even after the last one.
                if state != p.reported || state == .done { p.reportedAt = now }
                p.reported = state
            }

            p.lastReport = now
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
        let id = local[id] == nil ? id : uniqueID(for: name)
        let project = Project(id: id, name: name, path: path.map { root(for: $0, machine: machine) }, now: now)
        local[id] = project
        rebuild()
        return id
    }

    // MARK: - To-dos

    @discardableResult
    func addTodo(_ text: String, to id: String) -> Todo? {
        guard let text = text.trimmed else { return nil }
        let now = Date.now
        let todo = Todo(text: text, created: now, updated: now)
        update(id) { p in p.todos = Self.pruned((p.todos ?? []) + [todo], at: now) }
        return todo
    }

    /// Ticks, unticks or rewords one.
    func changeTodo(_ todoID: UUID, in id: String, done: Bool? = nil, text: String? = nil) {
        editTodo(todoID, in: id) { todo, now in
            if let text = text?.trimmed { todo.text = text }
            if let done, done != todo.done {
                todo.done = done
                todo.completed = done ? now : nil
            }
        }
    }

    func deleteTodo(_ todoID: UUID, in id: String) {
        editTodo(todoID, in: id) { todo, _ in todo.deleted = true }
    }

    func clearDoneTodos(in id: String) {
        for todo in self[id]?.doneTodos ?? [] { deleteTodo(todo.id, in: id) }
    }

    /// Changes a to-do in this Mac's copy of the project, taking it from the merged board first when
    /// it came from another Mac, so the change syncs back.
    private func editTodo(_ todoID: UUID, in id: String, _ change: (inout Todo, Date) -> Void) {
        guard var todo = projects[id]?.todos?.first(where: { $0.id == todoID }) else { return }
        let now = Date.now
        let wasDone = todo.done
        change(&todo, now)
        todo.updated = now
        update(id) { p in
            var todos = (p.todos ?? []).filter { $0.id != todoID }
            todos.append(todo)
            p.todos = Self.pruned(todos, at: now)
            if todo.done, !wasDone, !todo.deleted {
                p.log(Event(date: now, state: .done, symbol: "checkmark.square.fill", title: todo.text, detail: String(localized: "To-do done")))
            }
        }
    }

    /// Deletions are kept 30 days, long enough to reach every Mac.
    private static func pruned(_ todos: [Todo], at now: Date) -> [Todo] {
        todos.filter { !$0.deleted || now.timeIntervalSince($0.updated) < 30 * 24 * 3600 }
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        update(id) { $0.hidden = hidden }
    }

    /// Forgets a project for good. Discovery brings it back if Claude Code still has sessions there,
    /// so the board hides projects instead.
    func remove(_ id: String) {
        local[id] = nil
        rebuild()
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

    // MARK: - Background work from transcripts

    /// Sessions on this Mac that look idle but have background work running, going by their
    /// transcripts (work started while the board was down, or was a version that didn't know),
    /// and sessions shown waiting on work that has since ended.
    func checkBackgroundWork() {
        let now = Date.now
        let candidates = local.values.flatMap { project in
            project.sessions
                .filter { $0.machine == nil && ($0.state == .idle || $0.state == .background) && now.timeIntervalSince($0.updated) < BackgroundJob.timeout }
                .map { (project: project.id, session: $0.id, transcript: $0.transcript) }
        }
        guard !candidates.isEmpty else { return }
        Task {
            let scans = await Task.detached(priority: .utility) {
                candidates.compactMap { item -> (project: String, session: String, scan: TranscriptScan.Result)? in
                    guard let path = item.transcript ?? TranscriptScan.path(forSession: item.session),
                          let scan = TranscriptScan.scan(path, now: now) else { return nil }
                    return (item.project, item.session, scan)
                }
            }.value
            for item in scans {
                // Leave a session that has moved on since.
                guard let session = local[item.project]?.sessions.first(where: { $0.id == item.session }),
                      session.state == .idle || session.state == .background else { continue }
                let jobs = TranscriptScan.merge(session.background ?? [], with: item.scan, at: .now)
                let state: ProjectState = jobs.isEmpty ? .idle : .background
                guard jobs != (session.background ?? []) || state != session.state else { continue }
                update(item.project) { p in
                    guard let index = p.sessions.firstIndex(where: { $0.id == item.session }) else { return }
                    p.sessions[index].background = jobs
                    if p.sessions[index].state != state {
                        p.sessions[index].state = state
                        p.sessions[index].since = p.sessions[index].updated
                    }
                }
            }
        }
    }

    @ObservationIgnored private var endingChecks: [String: Date] = [:]

    /// Sessions still shown working whose turn stopped without a Stop hook: on an API error (no
    /// connection, out of usage credits) or because you interrupted it. The transcript's last exchange
    /// says so; a quiet minute is the cue to look, once per quiet spell.
    func checkStoppedSessions() {
        let now = Date.now
        let candidates = local.values.flatMap { project in
            project.sessions
                .filter { $0.machine == nil && $0.state == .working && now.timeIntervalSince($0.updated) > 60 && endingChecks[$0.id] != $0.updated }
                .map { (project: project.id, session: $0.id, updated: $0.updated, transcript: $0.transcript) }
        }
        guard !candidates.isEmpty else { return }
        for item in candidates { endingChecks[item.session] = item.updated }
        Task {
            let endings = await Task.detached(priority: .utility) {
                candidates.compactMap { item -> (project: String, session: String, updated: Date, ending: TranscriptScan.Ending)? in
                    guard let path = item.transcript ?? TranscriptScan.path(forSession: item.session),
                          let ending = TranscriptScan.ending(of: path) else { return nil }
                    return (item.project, item.session, item.updated, ending)
                }
            }.value
            for item in endings {
                // Leave a session that has moved on since.
                guard let session = local[item.project]?.sessions.first(where: { $0.id == item.session }),
                      session.updated == item.updated, session.state == .working else { continue }
                update(item.project) { p in
                    guard let index = p.sessions.firstIndex(where: { $0.id == item.session }) else { return }
                    p.sessions[index].since = .now
                    switch item.ending {
                    case .apiError(let error):
                        p.sessions[index].state = .blocked
                        p.sessions[index].message = error
                        p.log(Event(date: .now, state: .blocked, symbol: ProjectState.blocked.symbol, title: error, detail: session.task))
                    case .interrupted:
                        p.sessions[index].state = .idle
                        p.sessions[index].message = nil
                        p.sessions[index].activity = String(localized: "Interrupted")
                    }
                }
            }
        }
    }

    // MARK: - Discovery

    func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        refreshDesktopChats()
        checkBackgroundWork()
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
                p.looseEnds = item.looseEnds.map { [$0] }
                if let bundleID = item.bundleID { p.bundleID = bundleID }
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

    // MARK: - Other Macs' boards

    private static func loadMachineID() -> String {
        if let saved = UserDefaults.standard.string(forKey: "FactoryMachineID") { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "FactoryMachineID")
        return id
    }

    /// Reads the other Macs' boards from iCloud Drive every few seconds, and shares this one.
    func startSync() {
        guard syncsWithOtherMacs, syncLoop == nil else { return }
        syncLoop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.readPeers()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        scheduleSyncWrite()
    }

    private func stopSync() {
        syncLoop?.cancel()
        syncLoop = nil
        peers = [:]
        peerDates = [:]
        rebuild()
    }

    private func readPeers() async {
        let (machineID, known) = (self.machineID, peerDates)
        let found = await Task.detached(priority: .utility) { SyncFolder.peers(excluding: machineID, known: known) }.value
        guard syncsWithOtherMacs else { return }
        var changed = false
        for peer in found {
            guard let board = peer.board else { continue }
            peers[peer.machineID] = board
            peerDates[peer.machineID] = peer.modified
            changed = true
        }
        // A Mac whose file is gone has stopped sharing.
        for id in peers.keys where !found.contains(where: { $0.machineID == id }) {
            peers[id] = nil
            peerDates[id] = nil
            changed = true
        }
        if changed {
            rebuild()
            refreshBadge()
        }
    }

    /// Shares this board, at most every five seconds: each write goes up to iCloud.
    func scheduleSyncWrite() {
        guard syncsWithOtherMacs, SyncFolder.isAvailable, syncWrite == nil else { return }
        let wait = max(0, 5 - Date.now.timeIntervalSince(lastSyncWrite))
        syncWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.syncWrite = nil
            self.lastSyncWrite = .now
            let board = SyncFolder.Board(machineID: machineID, machineName: machineName, updated: .now,
                                         projects: local.values.sorted { $0.id < $1.id })
            await Task.detached(priority: .utility) {
                do { try SyncFolder.write(board) } catch {}
            }.value
        }
    }

    /// Shares this board now, on the way out.
    func writeSyncNow() {
        guard syncsWithOtherMacs, SyncFolder.isAvailable else { return }
        try? SyncFolder.write(SyncFolder.Board(machineID: machineID, machineName: machineName, updated: .now,
                                               projects: local.values.sorted { $0.id < $1.id }))
    }

    /// The merged board: this Mac's projects, with each other Mac's projects joined to the same project
    /// here (by id, repository or name) or added as their own.
    private func rebuild() {
        var theirs: [String: [(project: Project, machine: String)]] = [:]
        for board in peers.values {
            for project in board.projects {
                theirs[key(for: project), default: []].append((project, board.machineName))
            }
        }
        var merged: [String: Project] = [:]
        for id in Set(local.keys).union(theirs.keys) {
            merged[id] = BoardMerge.combine(local[id], theirs[id] ?? [], thisMac: machineName)
        }
        projects = merged
        Notifier.shared.evaluate(merged, now: .now)
    }

    /// Which project here another Mac's project is.
    private func key(for project: Project) -> String {
        projectID(matching: project.id, name: project.name, repo: project.repo)
    }

    /// The project here that another Mac's project is: the same id, repository or name. Its own id
    /// when there's none, as on the merged board.
    func projectID(matching id: String, name: String, repo: String?) -> String {
        if local[id] != nil { return id }
        if let repo, let same = local.values.first(where: { $0.repo == repo }) { return same.id }
        if let same = local.values.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return same.id }
        return id
    }

    /// The Dock icon counts the projects waiting on you.
    func refreshBadge() {
        let waiting = projects.values.filter { !$0.hidden && $0.state(at: now).needsYou }.count
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
            local = Dictionary(saved.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            machines = saved.machines ?? [:]
            // Earlier versions took the app's notes for tasks ("Linked sessions now…"): drop them.
            for id in Array(local.keys) {
                local[id]?.events.removeAll { HookText.isAppNote($0.title) }
                for index in local[id]?.sessions.indices ?? 0..<0 where HookText.isAppNote(local[id]?.sessions[index].task ?? "") {
                    local[id]?.sessions[index].task = nil
                }
            }
            rebuild()
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
            let data = try Self.encoder.encode(Saved(projects: local.values.sorted { $0.id < $1.id }, machines: machines))
            try data.write(to: fileURL, options: .atomic)
            scheduleSyncWrite()
        } catch {
            log.error("Couldn't save the board: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONDates.encoding
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONDates.decoding
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
