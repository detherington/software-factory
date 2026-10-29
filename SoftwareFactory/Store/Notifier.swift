import AppKit
import Observation
import UserNotifications

/// Tells you when something changes that you'd want to know about, instead of waiting for you to
/// look: a session that needs you, a question, a block, background work finishing, a release.
///
/// After each change the board calls `evaluate`, which compares what's on the board with what it
/// has already told you about. Only what began in the last two minutes notifies, so opening the
/// app, or another Mac's board catching up, doesn't replay old news.
@MainActor
@Observable
final class Notifier {
    static let shared = Notifier()

    enum Kind: String, CaseIterable, Identifiable {
        case needsYou, yourCall, blocked, backgroundDone, shipped, finished

        var id: Self { self }

        var label: String {
            switch self {
            case .needsYou: String(localized: "Needs you")
            case .yourCall: String(localized: "Your call")
            case .blocked: String(localized: "Blocked")
            case .backgroundDone: String(localized: "Background work finished")
            case .shipped: String(localized: "Shipped")
            case .finished: String(localized: "Turn finished, no question")
            }
        }

        /// Turn finished is the noisy one: off unless you want it.
        var onByDefault: Bool { self != .finished }
        /// The ones that want you now make a sound.
        var urgent: Bool { self == .needsYou || self == .yourCall || self == .blocked }

        init?(_ state: ProjectState) {
            switch state {
            case .waiting: self = .needsYou
            case .yourCall: self = .yourCall
            case .blocked: self = .blocked
            default: return nil
            }
        }
    }

    /// What it decided to say, newest first: the debug API shows these.
    struct Notice: Encodable {
        var key: String
        var kind: String
        var title: String
        var subtitle: String?
        var body: String
        var project: String
        var session: String?
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var recent: [Notice] = []

    @ObservationIgnored private var started = false
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var lastStates: [String: ProjectState] = [:]
    @ObservationIgnored private var lastJobs: [String: [BackgroundJob]] = [:]
    /// Delivered notifications about states that may resolve: removed once they have.
    @ObservationIgnored private var standing: Set<String> = []
    /// Held for a moment, so a burst arriving as separate changes still goes out as one.
    @ObservationIgnored private var queue: [(notice: Notice, standing: Bool, sound: Bool)] = []
    @ObservationIgnored private var flush: Task<Void, Never>?

    /// `-FactoryNotificationsDryRun YES`: decide, record, but post nothing (for testing).
    private let dryRun = UserDefaults.standard.bool(forKey: "FactoryNotificationsDryRun")

    // MARK: - Settings

    func isEnabled(_ kind: Kind) -> Bool {
        _ = settingsChanged
        return UserDefaults.standard.object(forKey: "FactoryNotify.\(kind.rawValue)") as? Bool ?? kind.onByDefault
    }

    func setEnabled(_ kind: Kind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "FactoryNotify.\(kind.rawValue)")
        settingsChanged += 1
    }

    var includesOtherMacs: Bool {
        get { _ = settingsChanged; return UserDefaults.standard.object(forKey: "FactoryNotifyOtherMacs") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "FactoryNotifyOtherMacs"); settingsChanged += 1 }
    }

    var playsSound: Bool {
        get { _ = settingsChanged; return UserDefaults.standard.object(forKey: "FactoryNotifySound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "FactoryNotifySound"); settingsChanged += 1 }
    }

    /// Bumped when a setting changes, so views reading them refresh.
    private(set) var settingsChanged = 0

    // MARK: - Starting

    /// Asks once for permission and sets up the notification buttons.
    func start(delegate: UNUserNotificationCenterDelegate) {
        started = true
        guard !dryRun else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let openChat = UNNotificationAction(identifier: "open-chat", title: String(localized: "Open Chat"), options: [.foreground])
        let showBoard = UNNotificationAction(identifier: "show-board", title: String(localized: "Show on Board"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "session", actions: [openChat, showBoard], intentIdentifiers: []),
            UNNotificationCategory(identifier: "project", actions: [showBoard], intentIdentifiers: []),
        ])
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
        }
    }

    func refreshAuthorization() async {
        guard !dryRun else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Deciding

    func evaluate(_ projects: [String: Project], now: Date) {
        guard started else { return }
        var notices: [(notice: Notice, standing: Bool, sound: Bool)] = []
        var holding: Set<String> = []
        func fresh(_ date: Date) -> Bool { now.timeIntervalSince(date) < 120 }

        for project in projects.values where !project.hidden {
            let live = Set(project.liveSessions(at: now).map(\.id))
            for session in project.sessions {
                guard session.machine == nil || includesOtherMacs else { continue }
                let place = session.machine.map { String(localized: "on \($0)") }

                // Needs you, your call, blocked: once each time a session enters one.
                if live.contains(session.id), let kind = Kind(session.state) {
                    let key = "\(session.id)|\(session.state.rawValue)|\(Int(session.since.timeIntervalSince1970))"
                    holding.insert(key)
                    if !seen.contains(key), fresh(session.since), isEnabled(kind) {
                        notices.append((notice(kind, key: key, project: project, session: session, place: place), true, kind.urgent))
                    }
                    seen.insert(key)
                }

                // A turn that finished without a question.
                let before = lastStates[session.id]
                lastStates[session.id] = session.state
                if before == .working, session.state == .idle, fresh(session.since), isEnabled(.finished) {
                    let key = "\(session.id)|finished|\(Int(session.since.timeIntervalSince1970))"
                    if seen.insert(key).inserted {
                        notices.append((notice(.finished, key: key, project: project, session: session, place: place), false, false))
                    }
                }

                // Background commands and agents that ended (monitors expire and wake-ups fire by design).
                let jobs = session.background ?? []
                if let earlier = lastJobs[session.id], isEnabled(.backgroundDone) {
                    let current = Set(jobs.map(\.id))
                    for job in earlier where !current.contains(job.id) && (job.kind == .command || job.kind == .agent) {
                        let key = "\(session.id)|job|\(job.id)"
                        if seen.insert(key).inserted {
                            var finished = notice(.backgroundDone, key: key, project: project, session: session, place: place)
                            finished.body = job.title
                            notices.append((finished, false, false))
                        }
                    }
                }
                lastJobs[session.id] = jobs
            }

            // A release, or a block reported for the project.
            if project.reported == .done || project.reported == .blocked {
                let kind: Kind = project.reported == .done ? .shipped : .blocked
                let key = "\(project.id)|\(project.reported.rawValue)|\(Int(project.reportedAt.timeIntervalSince1970))"
                if project.reported == .blocked { holding.insert(key) }
                if !seen.contains(key), fresh(project.reportedAt), isEnabled(kind) {
                    notices.append((notice(kind, key: key, project: project, session: nil, place: nil), kind == .blocked, kind.urgent))
                }
                seen.insert(key)
            }
        }

        // What resolved (an answer, an unblock) leaves Notification Center.
        let resolved = standing.subtracting(holding)
        if !resolved.isEmpty {
            standing.subtract(resolved)
            if !dryRun { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(resolved)) }
        }
        guard !notices.isEmpty else { return }
        queue += notices
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.send()
        }
    }

    /// Sends what's queued: one by one, or a burst (a board catching up, several sessions at once) as one.
    private func send() {
        let notices = queue
        queue = []
        flush = nil
        guard notices.count > 3 else {
            for item in notices { deliver(item.notice, standing: item.standing, sound: item.sound) }
            return
        }
        let needYou = notices.filter { ["needsYou", "yourCall", "blocked"].contains($0.notice.kind) }.count
        let summary = Notice(key: "summary|\(Int(Date.now.timeIntervalSince1970))", kind: "summary",
                             title: needYou > 0 ? String(localized: "\(needYou) projects need you") : String(localized: "\(notices.count) updates"),
                             body: notices.map { $0.notice.title }.joined(separator: " · "), project: "")
        deliver(summary, standing: false, sound: needYou > 0)
    }

    private func notice(_ kind: Kind, key: String, project: Project, session: Session?, place: String?) -> Notice {
        let name = project.name
        let (title, body): (String, String) = switch kind {
        case .needsYou: (String(localized: "\(name) needs you"), session?.message ?? session?.task ?? "")
        case .yourCall: (String(localized: "\(name): your call"), session?.message ?? "")
        case .blocked: (String(localized: "\(name) is blocked"), session?.message ?? project.note ?? "")
        case .backgroundDone: (String(localized: "\(name): background work finished"), "")
        case .shipped: (String(localized: "\(name) shipped"), project.note ?? project.task ?? "")
        case .finished: (String(localized: "\(name) finished a turn"), session?.task ?? "")
        }
        return Notice(key: key, kind: kind.rawValue, title: title, subtitle: place, body: body, project: project.id, session: session?.id)
    }

    // MARK: - Delivering

    private func deliver(_ notice: Notice, standing isStanding: Bool, sound: Bool) {
        recent.insert(notice, at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
        if isStanding { standing.insert(notice.key) }
        guard !dryRun else { return }

        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = notice.subtitle { content.subtitle = subtitle }
        content.body = notice.body
        // Grouped by project in Notification Center.
        content.threadIdentifier = notice.project.isEmpty ? "summary" : notice.project
        content.categoryIdentifier = notice.session == nil ? "project" : "session"
        content.userInfo = ["project": notice.project, "session": notice.session ?? ""]
        if sound, playsSound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.key, content: content, trigger: nil))
    }

    // MARK: - Answering

    /// A click, or a button: the session's Claude Desktop chat when it has one, else the board.
    func respond(action: String, project id: String, session sessionID: String) {
        let store = ProjectStore.shared
        let session = store[id]?.sessions.first { $0.id == sessionID }
        if action != "show-board", let session, let chat = store.chat(for: session) {
            Reveal.chat(chat)
            return
        }
        if !id.isEmpty { Navigator.shared.open(id) } else { Navigator.shared.selection = .board }
        Navigator.shared.openBoard?()
        NSApplication.shared.activate()
    }
}
