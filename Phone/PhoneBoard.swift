import CloudKit
import Observation
import UserNotifications
import WidgetKit

/// The board on the iPhone: fetched from your private iCloud database, where the Macs leave it,
/// when the app opens, when you pull to refresh, and when iCloud says it changed. The widgets read
/// what it fetched last. To-dos and snoozes changed here go to the inbox for the Macs, and show at
/// once: each stays applied until a fetched board has it.
@MainActor
@Observable
final class PhoneBoard {
    static let shared = PhoneBoard()

    private(set) var projects: [Project] = []
    /// Today's digest, as a Mac made it.
    private(set) var digest: Digest?
    /// The Passport's numbers, as a Mac added them up.
    private(set) var passport: CloudBoard.Passport?
    private(set) var fetched: Date?
    private(set) var problem: String?
    /// Permission prompts answered here, by id, until the Mac that holds them has passed it on.
    private(set) var answeredPermissions: [String: Bool] = [:]
    /// Replies sent from here, by session, and when: until a Mac passes one on, its card says so.
    private(set) var replied: [String: Date] = [:]
    /// The chats your Macs run, by id, with what you wrote in them here that hasn't come back yet.
    private(set) var chats: [String: HostedChat] = [:]
    @ObservationIgnored private var fetchedChats: [String: HostedChat] = [:]
    /// Chats started here that no Mac has picked up yet, and lines written here not yet in a fetched chat.
    @ObservationIgnored private var startedChats: [String: HostedChat] = [:]
    @ObservationIgnored private var writtenLines: [String: [ChatItem]] = [:]
    private(set) var isRefreshing = false
    /// Ticks so relative times and stale sessions move on.
    private(set) var now = Date.now
    /// The project to show: a widget's, or an alert's.
    var opened: String?

    @ObservationIgnored private var clock: Task<Void, Never>?
    /// Changes made here that a fetched board doesn't have yet.
    @ObservationIgnored private var pendingTodos: [UUID: (project: String, todo: Todo)] = [:]
    @ObservationIgnored private var pendingSnoozes: [String: Date] = [:]
    @ObservationIgnored private var inboxReady = false
    /// `-FactorySampleBoard <file>` (Debug): a board from a file instead of iCloud, for looking at
    /// the screens in the Simulator.
    @ObservationIgnored private let sample: String?

    init() {
        #if DEBUG
        sample = UserDefaults.standard.string(forKey: "FactorySampleBoard")
        #else
        sample = nil
        #endif
        if let sample, let data = try? Data(contentsOf: URL(fileURLWithPath: sample)) {
            projects = CloudBoard.decode([Project].self, from: data) ?? []
            #if DEBUG
            digest = UserDefaults.standard.string(forKey: "FactorySampleDigest")
                .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                .flatMap { CloudBoard.decode(Digest.self, from: $0) }
            passport = UserDefaults.standard.string(forKey: "FactorySamplePassport")
                .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                .flatMap { CloudBoard.decode(CloudBoard.Passport.self, from: $0) }
            // `-FactoryOpen <project id | today>`: starts there, as a link would, without iOS asking first.
            opened = UserDefaults.standard.string(forKey: "FactoryOpen")
            #endif
            fetched = .now
        } else if let cache = BoardCache.read() {
            projects = cache.projects
            digest = cache.digest
            passport = cache.passport
            fetched = cache.fetched
        }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.now = .now
            }
        }
    }

    var board: [Project] { projects.board(at: now) }
    var live: [Project] { board.filter { $0.state(at: now).isLive } }
    var resting: [Project] { board.filter { !$0.state(at: now).isLive } }
    func count(_ state: ProjectState) -> Int { projects.count(state, at: now) }
    subscript(id: String) -> Project? { projects.first { $0.id == id } }

    // MARK: - iCloud

    /// Asks to notify, and subscribes to the board's changes (silent) and to alerts (shown).
    func setUp() async {
        guard sample == nil else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard let database = CloudBoard.container?.privateCloudDatabase else { return }
        do {
            // Only what's missing: a Mac makes the alerts subscription too (see PhoneShare).
            let existing = Set(try await database.allSubscriptions().map(\.subscriptionID))
            let missing = [CloudBoard.boardChangesSubscription(), CloudBoard.alertsSubscription()].filter { !existing.contains($0.subscriptionID) }
            if !missing.isEmpty {
                let (saved, _) = try await database.modifySubscriptions(saving: missing, deleting: [])
                // Each is saved, or refused, on its own.
                for case .failure(let error) in saved.values {
                    problem = String(localized: "Alerts couldn't be set up: \(Self.describe(error))")
                }
            }
        } catch {
            problem = String(localized: "Alerts couldn't be set up: \(Self.describe(error))")
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing, sample == nil else { return }
        guard let database = CloudBoard.container?.privateCloudDatabase else {
            problem = String(localized: "This build has no iCloud container.")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let board = try await CloudBoard.fetchBoard(from: database)
            projects = board.projects
            fetchedChats = Dictionary(board.chats.map { ($0.id, $0) }) { first, second in first.updated > second.updated ? first : second }
            applyWrittenLines()
            digest = board.digest
            passport = board.passport ?? passport
            fetched = .now
            now = .now
            problem = nil
            reapplyPending()
            saveCache()
            await clearSettledAlerts()
        } catch {
            problem = Self.describe(error)
        }
    }

    // MARK: - Changes made here

    func addTodo(_ text: String, to project: Project) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = Date.now
        change(Todo(text: text, created: now, updated: now), in: project)
    }

    func setTodo(_ todo: Todo, done: Bool, in project: Project) {
        var todo = todo
        todo.done = done
        todo.completed = done ? .now : nil
        todo.updated = .now
        change(todo, in: project)
    }

    func deleteTodo(_ todo: Todo, in project: Project) {
        var todo = todo
        todo.deleted = true
        todo.updated = .now
        change(todo, in: project)
    }

    /// Answers a permission prompt: the Mac whose hook waits for it reads the answer from the inbox
    /// within a few seconds, and passes it to Claude Code.
    func answer(_ ask: PermissionAsk, reply: PermissionAsk.Reply, in project: Project) {
        let answers: [String: String]? = if case .answers(let answers) = reply { answers } else { nil }
        answeredPermissions[ask.id] = reply != .deny
        send(CloudBoard.Change(kind: .permission, project: project.id, projectName: project.name,
                               permission: ask.id, allow: reply != .deny, answered: .now, answers: answers))
    }

    /// Answers a prompt from its alert's Allow or Deny, perhaps with the app in the background: done
    /// once the answer is in the inbox.
    func answer(ask: String, allow: Bool, project: String?) async {
        answeredPermissions[ask] = allow
        await save(CloudBoard.Change(kind: .permission, project: project, permission: ask, allow: allow, answered: .now))
    }

    /// Replies to a session whose turn ended, from its card: the Mac whose hook waits on it passes it on.
    func reply(to session: Session, text: String, in project: Project) {
        replied[session.id] = .now
        send(CloudBoard.Change(kind: .reply, project: project.id, projectName: project.name, answered: .now, session: session.id, text: text))
    }

    /// Replies from an alert's buttons or Reply, perhaps with the app in the background: done once the
    /// reply is in the inbox.
    func reply(session: String, text: String, project: String?) async {
        replied[session] = .now
        await save(CloudBoard.Change(kind: .reply, project: project, answered: .now, session: session, text: text))
    }

    /// Whether a reply sent from here is still on its way to the session's turn that ended.
    func hasReplied(to session: Session) -> Bool {
        (replied[session.id] ?? .distantPast) > session.since
    }

    /// Alerts for prompts settled since (answered anywhere, or their time up), and for turns a reply
    /// can no longer reach, leave Notification Center, and so do the reply buttons the extension
    /// made for them. One that just came may be newer than the board fetched, so it stays a minute.
    private func clearSettledAlerts() async {
        let now = Date.now
        let open = Set(projects.flatMap { $0.sessions.compactMap { $0.permission?.isOpen(at: now) == true ? $0.permission?.id : nil } })
        let replying = Set(projects.flatMap { $0.sessions.filter { $0.ask != nil && $0.canReply(at: now) }.map(\.id) })
        let center = UNUserNotificationCenter.current()
        let settled = await center.deliveredNotifications().filter { notification in
            guard now.timeIntervalSince(notification.date) > 60 else { return false }
            let info = notification.request.content.userInfo
            if let session = PermissionAlert.replySession(in: info) { return !replying.contains(session) }
            guard let ask = PermissionAlert.prompt(in: info) else { return false }
            return !open.contains(ask)
        }
        center.removeDeliveredNotifications(withIdentifiers: settled.map(\.request.identifier))
        let categories = await center.notificationCategories()
        let kept = categories.filter { !$0.identifier.hasPrefix("reply.") || replying.contains(String($0.identifier.dropFirst("reply.".count))) }
        if kept.count < categories.count { center.setNotificationCategories(kept) }
    }

    // MARK: - Chats

    func chats(for project: String) -> [HostedChat] {
        chats.values.filter { $0.project == project }.sorted { $0.updated > $1.updated }
    }

    /// Writes in a chat a Mac runs: it shows here at once, and the Mac passes it to Claude as yours.
    func write(_ text: String, in chat: HostedChat) {
        writtenLines[chat.id, default: []].append(ChatItem(id: "here-\(UUID().uuidString)", kind: .user, text: text, date: .now))
        applyWrittenLines()
        send(CloudBoard.Change(kind: .message, project: chat.project, answered: .now, session: chat.id, text: text))
    }

    /// Stops the turn under way, on the Mac.
    func interrupt(_ chat: HostedChat) {
        send(CloudBoard.Change(kind: .interrupt, project: chat.project, answered: .now, session: chat.id))
    }

    /// A new chat in a project, which a Mac with its folder starts. Returns its id.
    func startChat(in project: Project, text: String) -> String {
        let id = UUID().uuidString.lowercased()
        let line = ChatItem(id: "here-\(UUID().uuidString)", kind: .user, text: text, date: .now)
        startedChats[id] = HostedChat(id: id, project: project.id, title: text.split(separator: "\n").first.map(String.init), items: [line],
                                      status: .starting, updated: .now)
        applyWrittenLines()
        send(CloudBoard.Change(kind: .start, project: project.id, projectName: project.name, answered: .now, session: id, text: text))
        return id
    }

    /// The fetched chats, with what was written here and hasn't come back from a Mac yet. A line is
    /// back once the chat has what you wrote, from about when you wrote it; a chat, once a Mac sends it.
    private func applyWrittenLines() {
        var merged = fetchedChats
        startedChats = startedChats.filter { fetchedChats[$0.key] == nil && Date.now.timeIntervalSince($0.value.updated) < 86_400 }
        for (id, chat) in startedChats { merged[id] = chat }
        for (id, lines) in writtenLines {
            guard var chat = merged[id] else { continue }
            let waiting = lines.filter { line in
                !chat.items.contains { $0.kind == .user && $0.text == line.text && $0.date > line.date.addingTimeInterval(-60) }
                    && Date.now.timeIntervalSince(line.date) < 86_400
            }
            writtenLines[id] = waiting.isEmpty ? nil : waiting
            guard !waiting.isEmpty else { continue }
            chat.items += waiting
            if !chat.status.isBusy, chat.status != .waiting { chat.status = .working }
            merged[id] = chat
        }
        chats = merged
    }

    /// Hides a nudge from Today, here and on the Macs, for a day or a week.
    func snooze(_ nudge: Nudge, days: Int) {
        let now = Date.now
        let until = now.addingTimeInterval(Double(days) * 86_400)
        pendingSnoozes[nudge.id] = until
        applySnoozes()
        saveCache()
        send(CloudBoard.Change(kind: .snooze, nudge: nudge.id, snooze: DigestState.Snooze(until: until, set: now)))
    }

    private func change(_ todo: Todo, in project: Project) {
        pendingTodos[todo.id] = (project.id, todo)
        apply(todo, to: project.id)
        saveCache()
        send(CloudBoard.Change(kind: .todo, project: project.id, projectName: project.name, todo: todo))
    }

    private func apply(_ todo: Todo, to projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var todos = (projects[index].todos ?? []).filter { $0.id != todo.id }
        todos.append(todo)
        projects[index].todos = todos
        // Today's old to-dos: one done or deleted leaves the list.
        guard var digest, todo.done || todo.deleted else { return }
        for index in digest.todos.indices { digest.todos[index].todos?.removeAll { $0.id == todo.id } }
        digest.todos.removeAll { $0.todos?.isEmpty ?? true }
        self.digest = digest
    }

    private func applySnoozes() {
        guard var digest else { return }
        let snoozed = { (nudge: Nudge) in self.pendingSnoozes[nudge.id].map { $0 > .now } ?? false }
        digest.snoozed += (digest.waiting + digest.looseEnds + digest.todos).filter(snoozed)
        digest.waiting.removeAll(where: snoozed)
        digest.looseEnds.removeAll(where: snoozed)
        digest.todos.removeAll(where: snoozed)
        self.digest = digest
    }

    /// After a fetch: what the Macs have folded in is done with; the rest is applied again.
    private func reapplyPending() {
        // A prompt is done with once no session asks it any more.
        let asked = Set(projects.flatMap { $0.sessions.compactMap { $0.permission?.id } })
        answeredPermissions = answeredPermissions.filter { asked.contains($0.key) }
        replied = replied.filter { Date.now.timeIntervalSince($0.value) < 86_400 }
        for (id, item) in pendingTodos {
            let fetched = projects.first { $0.id == item.project }?.todos?.first { $0.id == id }
            if let fetched, fetched.updated >= item.todo.updated { pendingTodos[id] = nil } else { apply(item.todo, to: item.project) }
        }
        // A snooze is done with once a Mac's digest has it, or once it runs out.
        let snoozedThere = Set(digest?.snoozed.map(\.id) ?? [])
        pendingSnoozes = pendingSnoozes.filter { !snoozedThere.contains($0.key) && $0.value > .now }
        applySnoozes()
    }

    private func saveCache() {
        guard sample == nil, let fetched else { return }
        BoardCache.write(BoardCache.Saved(projects: projects, fetched: fetched, digest: digest, passport: passport))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Puts a change in the inbox, for the Macs.
    private func send(_ change: CloudBoard.Change) {
        Task { await save(change) }
    }

    private func save(_ change: CloudBoard.Change) async {
        guard sample == nil, let database = CloudBoard.container?.privateCloudDatabase else { return }
        do {
            if !inboxReady {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: CloudBoard.inboxZoneID)], deleting: [])
                inboxReady = true
            }
            _ = try await database.save(CloudBoard.record(for: change))
        } catch {
            problem = String(localized: "Couldn't send that to your Macs: \(Self.describe(error))")
        }
    }

    /// softwarefactory://project/<id>, from a widget, or softwarefactory://today or ://passport.
    func open(_ url: URL) {
        guard url.scheme == "softwarefactory" else { return }
        if url.host() == "today" || url.host() == "passport" { opened = url.host() }
        if url.host() == "project" { opened = url.pathComponents.dropFirst().first }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .zoneNotFound, .userDeletedZone:
            return String(localized: "Nothing from your Macs yet. Open Software Factory on a Mac signed in to the same iCloud account.")
        case .notAuthenticated: return String(localized: "Sign in to iCloud in Settings to see your board.")
        case .networkUnavailable, .networkFailure: return String(localized: "No connection to iCloud.")
        default: return error.localizedDescription
        }
    }
}
