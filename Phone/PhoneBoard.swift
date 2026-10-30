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
    func answer(_ ask: PermissionAsk, allow: Bool, in project: Project) {
        answeredPermissions[ask.id] = allow
        send(CloudBoard.Change(kind: .permission, project: project.id, projectName: project.name,
                               permission: ask.id, allow: allow, answered: .now))
    }

    /// Answers a prompt from its alert's Allow or Deny, perhaps with the app in the background: done
    /// once the answer is in the inbox.
    func answer(ask: String, allow: Bool, project: String?) async {
        answeredPermissions[ask] = allow
        await save(CloudBoard.Change(kind: .permission, project: project, permission: ask, allow: allow, answered: .now))
    }

    /// Alerts for prompts settled since (answered anywhere, or their time up) leave Notification
    /// Center. One that just came may be newer than the board fetched, so it stays a minute.
    private func clearSettledAlerts() async {
        let now = Date.now
        let open = Set(projects.flatMap { $0.sessions.compactMap { $0.permission?.isOpen(at: now) == true ? $0.permission?.id : nil } })
        let center = UNUserNotificationCenter.current()
        let settled = await center.deliveredNotifications().filter { notification in
            guard let ask = PermissionAlert.ask(in: notification.request.content.userInfo) else { return false }
            return !open.contains(ask) && now.timeIntervalSince(notification.date) > 60
        }
        center.removeDeliveredNotifications(withIdentifiers: settled.map(\.request.identifier))
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
