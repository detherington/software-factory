import Foundation

/// Where a project stands. Color means state, everywhere on the board.
enum ProjectState: String, Codable, CaseIterable, Sendable {
    /// An agent stopped for you: a permission prompt, a question, a plan to approve.
    case waiting
    /// Something is broken: a failing build, failing tests, a missing key; or a session stopped on an
    /// error (a usage limit, no connection).
    case blocked
    /// A session finished its turn with a question for you: Claude Desktop's next-step box asked one.
    case yourCall
    /// An agent is working on it right now.
    case working
    /// An agent finished its turn but is waiting on work it started: a background command, an agent,
    /// a monitor, a scheduled wake-up. It picks up again by itself.
    case background
    /// A milestone shipped.
    case done
    /// Nothing happening.
    case idle

    /// Accepts the API's spelling and a few friendly aliases.
    init?(api raw: String) {
        let key = raw.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch key {
        case "working", "active", "running", "busy", "in_progress", "building", "testing": self = .working
        case "waiting", "needs_input", "needs_you", "input", "review", "permission", "question": self = .waiting
        case "background", "watching", "monitoring", "listening", "scheduled": self = .background
        case "yourcall", "your_call", "your_turn", "decision", "decide": self = .yourCall
        case "blocked", "error", "failing", "failed", "broken", "stuck": self = .blocked
        case "done", "shipped", "complete", "completed", "released", "finished": self = .done
        case "idle", "paused", "parked", "stopped", "quiet": self = .idle
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .waiting: "Needs you"
        case .blocked: "Blocked"
        case .yourCall: "Your call"
        case .working: "Working"
        case .background: "Background"
        case .done: "Shipped"
        case .idle: "Idle"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .yourCall: "questionmark.bubble.fill"
        case .working: "bolt.fill"
        case .background: "hourglass"
        case .done: "checkmark"
        case .idle: "moon.fill"
        }
    }

    var swatch: Swatch {
        switch self {
        case .waiting: .amber
        case .blocked: .ember
        case .yourCall: .tangerine
        case .working: .violet
        case .background: .sky
        case .done: .mint
        case .idle: .slate
        }
    }

    /// A state from a newer version of the app (on another Mac's board) reads as idle, rather than
    /// make the whole board unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProjectState(rawValue: raw) ?? .idle
    }

    /// Board order: what needs you first.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .blocked: 1
        case .yourCall: 2
        case .working: 3
        case .background: 4
        case .done: 5
        case .idle: 6
        }
    }

    /// On the board's Now row.
    var isLive: Bool { self != .done && self != .idle }

    /// Waiting on you, one way or another: the Dock and menu bar count these.
    var needsYou: Bool { self == .waiting || self == .yourCall }
}

/// What a project is, for its symbol.
enum Kind: String, Codable, CaseIterable, Sendable {
    case ios, mac, apple, game, web, site, cloud, tool, library, other

    init?(api raw: String) {
        switch raw.lowercased() {
        case "ios", "iphone", "ipad": self = .ios
        case "mac", "macos": self = .mac
        case "apple", "app", "swift", "multiplatform": self = .apple
        case "game", "games": self = .game
        case "web", "webapp", "pwa", "react", "node": self = .web
        case "site", "website", "static": self = .site
        case "cloud", "worker", "server", "api", "backend": self = .cloud
        case "tool", "cli", "script", "python": self = .tool
        case "library", "package", "framework", "sdk": self = .library
        case "other": self = .other
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .ios: "iphone"
        case .mac: "macwindow"
        case .apple: "apps.iphone"
        case .game: "gamecontroller.fill"
        case .web: "globe"
        case .site: "safari.fill"
        case .cloud: "cloud.fill"
        case .tool: "terminal.fill"
        case .library: "shippingbox.fill"
        case .other: "folder.fill"
        }
    }
}

/// One step of a plan: a project's milestone checklist, or an agent's task list.
struct Step: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case todo, active, done }

    var title: String
    var status: Status
}

extension Step {
    /// Finishes the step under way (or, with none under way, the first still to do) and starts the
    /// next. Returns the step it finished.
    @discardableResult
    static func advance(_ steps: inout [Step]) -> Step? {
        guard let current = steps.firstIndex(where: { $0.status == .active }) ?? steps.firstIndex(where: { $0.status == .todo }) else {
            return nil
        }
        steps[current].status = .done
        if let next = steps[current...].firstIndex(where: { $0.status == .todo }) { steps[next].status = .active }
        return steps[current]
    }
}

/// What a working session is doing, beyond "working": shown in the card's chip, in the working color.
enum WorkMode: String, Codable, Sendable {
    case planning, testing, building, shipping, compacting

    var label: String {
        switch self {
        case .planning: String(localized: "Planning")
        case .testing: String(localized: "Testing")
        case .building: String(localized: "Building")
        case .shipping: String(localized: "Shipping")
        case .compacting: String(localized: "Compacting")
        }
    }

    var symbol: String {
        switch self {
        case .planning: "list.bullet.clipboard.fill"
        case .testing: "testtube.2"
        case .building: "hammer.fill"
        case .shipping: "paperplane.fill"
        case .compacting: "arrow.down.right.and.arrow.up.left"
        }
    }
}

/// Something you mean to tackle in a project: your own list, apart from Claude's plans.
struct Todo: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var text: String
    var done = false
    var created: Date
    /// When it last changed. Across Macs, the latest change to each item wins.
    var updated: Date
    var completed: Date?
    /// Deleted: kept for a while so the deletion reaches the other Macs instead of their copies
    /// bringing it back.
    var deleted = false

    /// Whether this copy wins over another of the same to-do: the later change, and on a tie the
    /// same pick on every Mac (a deletion, then a tick, then the text).
    func supersedes(_ other: Todo) -> Bool {
        if updated != other.updated { return updated > other.updated }
        if deleted != other.deleted { return deleted }
        if done != other.done { return done }
        return text > other.text
    }
}

/// Work in a project's folder that hasn't gone anywhere yet: uncommitted changes, unpushed commits.
struct LooseEnds: Codable, Hashable, Sendable {
    /// Files changed or added and not committed.
    var changes: Int
    /// Commits not pushed to the branch's upstream.
    var unpushed: Int
    /// The other Mac it's on; nil for this one.
    var machine: String?

    var isEmpty: Bool { changes == 0 && unpushed == 0 }
}

/// Work a session started to come back to: a background command, an async agent, a monitor, a
/// scheduled wake-up. Its notification (or TaskStop) ends it, by `id`.
struct BackgroundJob: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case command, agent, monitor, wakeup }

    var id: String
    var kind: Kind
    var title: String
    var started: Date
    /// When a monitor expires or a wake-up fires.
    var until: Date?

    /// Jobs without an end of their own stop counting after this, in case their notification was missed.
    static let timeout: TimeInterval = 6 * 60 * 60

    func isPending(at now: Date) -> Bool {
        if let until { return now < until.addingTimeInterval(90) }
        return now.timeIntervalSince(started) < Self.timeout
    }

    /// "Archive and upload build 5", "Wakes at 5:08 PM".
    var label: String {
        if kind == .wakeup, let until { return String(localized: "Wakes at \(until.formatted(date: .omitted, time: .shortened))") }
        return title
    }
}

/// A coding-agent session working in a project (or one of its worktrees).
struct Session: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var state: ProjectState
    /// What it was asked to do: the first line of the last prompt.
    var task: String?
    /// Why it's waiting: "Claude needs your permission to use Bash".
    var message: String?
    /// The worktree it runs in, when it isn't the project's own folder.
    var worktree: String?
    /// The last thing it did: "Edit · Theme.swift".
    var activity: String?
    /// The other Mac it runs on; nil for this one.
    var machine: String?
    /// Whether the app, not the user, started its current turn: a linked session's news, a
    /// background task's result. Such turns keep the task and aren't logged.
    var appTurn: Bool?
    /// Work it started to come back to.
    var background: [BackgroundJob]?
    /// Its transcript, on this Mac.
    var transcript: String?
    /// The question its turn is ending with, from Claude Desktop's next-step box, and whether the
    /// box said it can't go on without an answer.
    var ask: String?
    var askBlocks: Bool?
    /// What its current tool call is doing (a test run, a build, an upload, a compaction), and
    /// whether it's in plan mode.
    var action: WorkMode?
    var planMode: Bool?
    var steps: [Step]
    /// When its task list last changed.
    var stepsUpdated: Date?
    var started: Date
    var updated: Date
    /// When its current state began.
    var since: Date
}

extension Session {
    /// The tool call under way says more than plan mode does.
    var mode: WorkMode? { action ?? (planMode == true ? .planning : nil) }

    func pendingJobs(at now: Date) -> [BackgroundJob] {
        (background ?? []).filter { $0.isPending(at: now) }
    }

    /// "Archive and upload build 5", "Archive and upload build 5 and 2 more".
    func jobsSummary(at now: Date) -> String? {
        let jobs = pendingJobs(at: now)
        guard let first = jobs.first else { return nil }
        return jobs.count == 1 ? first.label : String(localized: "\(first.label) and \(jobs.count - 1) more")
    }
}

/// One line in a project's timeline.
struct Event: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    /// The state it speaks for, which picks its color.
    var state: ProjectState?
    var symbol: String?
    var title: String
    var detail: String?
    /// What it stands for elsewhere, so it isn't logged twice: a commit hash.
    var ref: String?
    /// The other Mac it came from; nil for this one.
    var machine: String?
}

struct Commit: Codable, Hashable, Sendable {
    var hash: String
    var date: Date
    var subject: String
}

struct Project: Codable, Identifiable, Hashable, Sendable {
    /// A stable slug: "tachyon-drifter".
    var id: String
    var name: String
    /// Three letters, like an airport code: "TDR".
    var code: String
    var path: String?
    /// What a report said it is; `detectedKind` is what discovery guessed from its files.
    var kind: Kind?
    var detectedKind: Kind?
    var symbol: String?
    /// A report's one-liner; `readme` is the first paragraph of its README.
    var summary: String?
    var readme: String?
    /// The state the last report set. What the board shows is `state(at:)`, which live sessions override.
    var reported: ProjectState = .idle
    var reportedAt: Date
    /// When a report (or a session ending one) last changed what was reported. Across Macs the latest wins.
    var lastReport: Date?
    var task: String?
    var note: String?
    var milestone: String?
    var progress: Double?
    var steps: [Step] = []
    /// When a report last set or ticked the steps.
    var stepsUpdated: Date?
    var version: String?
    var branch: String?
    var repo: String?
    var links: [String: String] = [:]
    var sessions: [Session] = []
    var events: [Event] = []
    var lastCommit: Commit?
    /// Uncommitted and unpushed work, one entry per Mac that has the folder.
    var looseEnds: [LooseEnds]?
    /// Your to-do list for it.
    var todos: [Todo]?
    var created: Date
    /// The newest sign of life from anywhere: a report, a hook, a transcript, a commit.
    var lastActivity: Date
    var hidden = false

    init(id: String, name: String, path: String?, now: Date = .now) {
        self.id = id
        self.name = name
        self.code = ProjectCode.make(from: name)
        self.path = path
        self.reportedAt = now
        self.created = now
        self.lastActivity = now
    }

    // Tolerant decoding, so fields added later don't strand older saved boards.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ProjectCode.make(from: name)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
        detectedKind = try c.decodeIfPresent(Kind.self, forKey: .detectedKind)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        readme = try c.decodeIfPresent(String.self, forKey: .readme)
        reported = try c.decodeIfPresent(ProjectState.self, forKey: .reported) ?? .idle
        task = try c.decodeIfPresent(String.self, forKey: .task)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        milestone = try c.decodeIfPresent(String.self, forKey: .milestone)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        stepsUpdated = try c.decodeIfPresent(Date.self, forKey: .stepsUpdated)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        links = try c.decodeIfPresent([String: String].self, forKey: .links) ?? [:]
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
        lastCommit = try c.decodeIfPresent(Commit.self, forKey: .lastCommit)
        looseEnds = try c.decodeIfPresent([LooseEnds].self, forKey: .looseEnds)
        todos = try c.decodeIfPresent([Todo].self, forKey: .todos)
        let created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .now
        self.created = created
        reportedAt = try c.decodeIfPresent(Date.self, forKey: .reportedAt) ?? created
        lastReport = try c.decodeIfPresent(Date.self, forKey: .lastReport)
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity) ?? created
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

// MARK: - What the board shows

extension Project {
    /// How long a session may go quiet in each state before the board stops believing it.
    static let workingTimeout: TimeInterval = 20 * 60
    static let waitingTimeout: TimeInterval = 24 * 60 * 60
    /// A reported "working" with no sign of life for this long reads as idle.
    static let reportedWorkingTimeout: TimeInterval = 45 * 60

    /// Sessions still believed to be working or waiting.
    func liveSessions(at now: Date) -> [Session] {
        sessions
            .filter { session in
                switch session.state {
                case .working: now.timeIntervalSince(session.updated) < Self.workingTimeout
                case .waiting, .yourCall, .blocked: now.timeIntervalSince(session.updated) < Self.waitingTimeout
                case .background: session.pendingJobs(at: now).isEmpty == false
                default: false
                }
            }
            .sorted { $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank : $0.updated > $1.updated }
    }

    /// The state the board shows: a session waiting on you beats everything, then a session at work,
    /// then whatever the last report said.
    func state(at now: Date) -> ProjectState {
        let live = liveSessions(at: now)
        if live.contains(where: { $0.state == .waiting }) { return .waiting }
        if reported == .blocked || live.contains(where: { $0.state == .blocked }) { return .blocked }
        if live.contains(where: { $0.state == .yourCall }) { return .yourCall }
        if live.contains(where: { $0.state == .working }) { return .working }
        if live.contains(where: { $0.state == .background }) { return .background }
        if reported == .working, now.timeIntervalSince(max(reportedAt, lastActivity)) > Self.reportedWorkingTimeout {
            return .idle
        }
        return reported
    }

    /// When the state on show began.
    func stateSince(at now: Date) -> Date {
        if let session = liveSessions(at: now).first, session.state == state(at: now) { return session.since }
        return reportedAt
    }

    /// The session the board leads with: live first, then the most recent.
    func leadSession(at now: Date) -> Session? {
        liveSessions(at: now).first ?? sessions.max { $0.updated < $1.updated }
    }

    /// What's happening, in a line.
    func headline(at now: Date) -> String? {
        if let live = liveSessions(at: now).first {
            if [.waiting, .yourCall, .blocked].contains(live.state), let message = live.message { return message }
            if let task = live.task { return task }
        }
        // What broke, or what shipped, says more than the task before it.
        if [.blocked, .done].contains(state(at: now)), let note { return note }
        return task ?? note
    }

    /// What its working session is doing, when the card says Working.
    func mode(at now: Date) -> WorkMode? {
        guard state(at: now) == .working else { return nil }
        return liveSessions(at: now).first { $0.state == .working && $0.mode != nil }?.mode
    }

    /// Your to-dos still to do, oldest first, and the ones done, latest first.
    var openTodos: [Todo] {
        (todos ?? []).filter { !$0.deleted && !$0.done }
            .sorted { $0.created != $1.created ? $0.created < $1.created : $0.id.uuidString < $1.id.uuidString }
    }
    var doneTodos: [Todo] { (todos ?? []).filter { !$0.deleted && $0.done }.sorted { ($0.completed ?? $0.updated) > ($1.completed ?? $1.updated) } }

    /// Loose ends worth showing: the ones that aren't empty.
    var openLooseEnds: [LooseEnds] { (looseEnds ?? []).filter { !$0.isEmpty } }

    /// The checklist on show: the project's own milestone steps, or else the lead session's task list.
    func displaySteps(at now: Date) -> [Step] {
        // The newest list wins: the reported checklist, or a session's own to-do list.
        let checklistTime = stepsUpdated ?? .distantPast
        let session = sessions
            .filter { !$0.steps.isEmpty }
            .max { ($0.stepsUpdated ?? $0.updated) < ($1.stepsUpdated ?? $1.updated) }
        if let session, steps.isEmpty || (session.stepsUpdated ?? session.updated) > checklistTime {
            return session.steps
        }
        // Shipping finishes the checklist that was set before it.
        if reported == .done, checklistTime <= reportedAt {
            return steps.map { Step(title: $0.title, status: .done) }
        }
        return steps
    }

    /// Progress from 0 to 1, as reported or counted from the steps.
    func fraction(at now: Date) -> Double? {
        if let progress { return progress }
        let shown = displaySteps(at: now)
        guard !shown.isEmpty else { return nil }
        return Double(shown.filter { $0.status == .done }.count) / Double(shown.count)
    }

    /// Whether its folder is on this Mac, for Finder and Terminal.
    var isOnThisMac: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var displaySymbol: String { symbol ?? (kind ?? detectedKind ?? .other).symbol }
    var displaySummary: String? { summary ?? readme }

    /// "~/Tachyon Drifter".
    var displayPath: String? {
        guard let path else { return nil }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Newest first, capped.
    mutating func log(_ event: Event) {
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }
}

/// Three-letter codes, like airport codes: "Tachyon Drifter" → "TDR", "Let Them Cook" → "LTC".
enum ProjectCode {
    static func make(from name: String) -> String {
        let words = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
        guard let first = words.first else { return "???" }
        switch words.count {
        case 1:
            return String(first.prefix(1)) + String(consonants(after: first, atLeast: 2).prefix(2)).padding(toLength: 2, withPad: "X", startingAt: 0)
        case 2:
            let second = words[1]
            return String(first.prefix(1)) + String(second.prefix(1)) + String(consonants(after: second, atLeast: 1).prefix(1))
        default:
            return words.prefix(3).map { String($0.prefix(1)) }.joined()
        }
    }

    /// The consonants after a word's first letter, or its letters if it has too few.
    private static func consonants(after word: String, atLeast count: Int) -> String {
        let rest = word.dropFirst()
        let found = rest.filter { !"AEIOUY".contains($0) && $0.isLetter }
        return found.count >= count ? String(found) : String(rest)
    }
}

/// "Tachyon Drifter" → "tachyon-drifter".
enum Slug {
    static func make(_ text: String) -> String {
        let parts = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.isEmpty ? "project" : parts.joined(separator: "-")
    }
}
