import Foundation

/// Something the morning digest reminds you of: a session waiting on you, a block, work left in a
/// folder, to-dos nobody has touched. Snoozing hides it for a day or a week.
struct Nudge: Identifiable, Hashable, Encodable, Sendable {
    enum Kind: String, Encodable, Sendable { case waiting, blocked, looseEnds, todos }

    /// The same while the thing it's about stays the same: a question asked again is a new one.
    var id: String
    var kind: Kind
    var project: String
    /// Since when: the question, the block, the last sign of life, the oldest to-do's last change.
    var since: Date
    /// The question, or what broke.
    var detail: String?
    var state: ProjectState?
    var session: String?
    /// The other Mac it's on; nil for this one.
    var machine: String?
    var looseEnds: [LooseEnds]?
    var todos: [Todo]?
}

/// The morning digest: the days since the last one, in numbers, and what's been left.
struct Digest: Encodable, Sendable {
    /// The start of each day it covers, oldest first: yesterday, or every day since the last digest.
    var days: [Date]
    var summary: PassportSummary
    var waiting: [Nudge]
    var looseEnds: [Nudge]
    var todos: [Nudge]
    /// Snoozed, so not in the lists above.
    var snoozed: [Nudge]
    /// When it went out, if it has today.
    var sent: Date?
    /// Its project names, by id, for the text.
    var names: [String: String]

    /// Nothing worked on and nothing left: no notification.
    var isEmpty: Bool { !hasWork && waiting.isEmpty && looseEnds.isEmpty && todos.isEmpty }

    var hasWork: Bool { summary.total.seconds >= 360 || summary.commits > 0 || summary.builds > 0 || !summary.releases.isEmpty }

    // MARK: - Finding what's been left

    /// What was left, across the board. `isArchived` says whether a session's chat was put away,
    /// which answers its question as far as the digest is concerned.
    static func nudges(in projects: [Project], now: Date, isArchived: (Session) -> Bool)
        -> (waiting: [Nudge], looseEnds: [Nudge], todos: [Nudge]) {
        var waiting: [Nudge] = []
        var looseEnds: [Nudge] = []
        var todos: [Nudge] = []
        for project in projects where !project.hidden {
            let state = project.state(at: now)
            let live = Set(project.liveSessions(at: now).map(\.id))

            if state == .blocked {
                let since = project.stateSince(at: now)
                waiting.append(Nudge(id: "blocked|\(project.id)|\(Int(since.timeIntervalSince1970))", kind: .blocked, project: project.id,
                                     since: since, detail: project.headline(at: now), state: .blocked))
            }
            // Questions: the live ones, and older ones the project hasn't moved on from since.
            for session in project.sessions where session.state.needsYou && now.timeIntervalSince(session.updated) < 3 * 86_400 {
                guard !isArchived(session) else { continue }
                guard live.contains(session.id) || project.lastActivity <= session.updated.addingTimeInterval(60) else { continue }
                waiting.append(Nudge(id: "question|\(session.id)|\(Int(session.since.timeIntervalSince1970))", kind: .waiting,
                                     project: project.id, since: session.since, detail: session.ask ?? session.message ?? session.task,
                                     state: session.state, session: session.id, machine: session.machine))
            }
            // Uncommitted or unpushed work in a project nobody has touched for a day.
            let ends = project.openLooseEnds
            if !ends.isEmpty, now.timeIntervalSince(project.lastActivity) >= 86_400, !state.isLive {
                looseEnds.append(Nudge(id: "loose|\(project.id)", kind: .looseEnds, project: project.id, since: project.lastActivity,
                                       looseEnds: ends))
            }
            // To-dos unchanged for a week.
            let stale = project.openTodos.filter { now.timeIntervalSince($0.updated) >= 7 * 86_400 }
            if let oldest = stale.map(\.updated).min() {
                todos.append(Nudge(id: "todos|\(project.id)", kind: .todos, project: project.id, since: oldest, todos: stale))
            }
        }
        waiting.sort { ($0.state?.rank ?? 9, $0.since) < ($1.state?.rank ?? 9, $1.since) }
        looseEnds.sort { $0.since < $1.since }
        todos.sort { $0.since < $1.since }
        return (waiting, looseEnds, todos)
    }

    // MARK: - Saying it

    /// "Yesterday", "Since Friday", "The last 7 days".
    var period: String {
        guard let first = days.first, days.count > 1 else { return String(localized: "Yesterday") }
        if days.count >= 7 { return String(localized: "The last \(days.count) days") }
        return String(localized: "Since \(first.formatted(.dateTime.weekday(.wide)))")
    }

    /// "Oct 28", "Oct 23 – 28".
    var range: String {
        guard let first = days.first, let last = days.last else { return "" }
        let style = Date.FormatStyle().month(.abbreviated).day()
        return first == last ? first.formatted(style) : "\(first.formatted(style)) – \(last.formatted(style))"
    }

    /// "6.5 hours, 31 commits, 3 TestFlight builds, 1 release".
    var work: String? {
        var parts: [String] = []
        let hours = Formats.hours(summary.total.seconds)
        if summary.total.seconds >= 360 { parts.append(hours == "1" ? String(localized: "1 hour") : String(localized: "\(hours) hours")) }
        if summary.commits > 0 { parts.append(summary.commits == 1 ? String(localized: "1 commit") : String(localized: "\(summary.commits) commits")) }
        if summary.builds > 0 {
            parts.append(summary.builds == 1 ? String(localized: "1 TestFlight build") : String(localized: "\(summary.builds) TestFlight builds"))
        }
        let releases = summary.releases.count
        if releases > 0 { parts.append(releases == 1 ? String(localized: "1 release") : String(localized: "\(releases) releases")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The notification's title: "Yesterday: 6.5 hours, 31 commits, 3 TestFlight builds".
    var title: String {
        if let work { return "\(period): \(work)" }
        return days.count > 1
            ? String(localized: "No Claude Code work \(period.lowercased())")
            : String(localized: "No Claude Code work yesterday")
    }

    /// The notification's body: "Waiting on you: Emanata and Rounds. Loose ends in Muesli. 5 to-dos untouched for a week."
    var body: String {
        var parts: [String] = []
        // A blocked project is said once, as blocked.
        let blockedProjects = Set(waiting.filter { $0.kind == .blocked }.map(\.project))
        let asking = names(waiting.filter { $0.kind == .waiting && !blockedProjects.contains($0.project) })
        if !asking.isEmpty { parts.append(String(localized: "Waiting on you: \(asking).")) }
        let blocked = names(waiting.filter { $0.kind == .blocked })
        if !blocked.isEmpty { parts.append(String(localized: "Blocked: \(blocked).")) }
        let loose = names(looseEnds)
        if !loose.isEmpty { parts.append(String(localized: "Loose ends in \(loose).")) }
        let count = todos.reduce(0) { $0 + ($1.todos?.count ?? 0) }
        if count > 0 {
            parts.append(count == 1 ? String(localized: "1 to-do untouched for a week.") : String(localized: "\(count) to-dos untouched for a week or more."))
        }
        return parts.isEmpty ? String(localized: "Nothing's waiting on you.") : parts.joined(separator: " ")
    }

    /// "Yesterday, Claude worked 6.5 hours across 4 projects."
    var sentence: String {
        guard summary.total.seconds >= 360 else {
            return days.count > 1
                ? String(localized: "No Claude Code work \(period.lowercased()).")
                : String(localized: "No Claude Code work yesterday.")
        }
        let hours = Formats.hours(summary.total.seconds)
        let worked = hours == "1" ? String(localized: "1 hour") : String(localized: "\(hours) hours")
        let projects = summary.rows.filter { !$0.id.isEmpty && $0.usage.seconds >= 60 }
        if projects.count == 1, let name = names[projects[0].id] {
            return String(localized: "\(period), Claude worked \(worked) on \(name).")
        }
        if projects.count > 1 { return String(localized: "\(period), Claude worked \(worked) across \(projects.count) projects.") }
        return String(localized: "\(period), Claude worked \(worked).")
    }

    /// "Emanata, Rounds and 2 more".
    private func names(_ nudges: [Nudge]) -> String {
        var seen: Set<String> = []
        let all = nudges.compactMap { nudge in seen.insert(nudge.project).inserted ? names[nudge.project] ?? nudge.project : nil }
        guard all.count > 3 else { return all.formatted(.list(type: .and)) }
        return String(localized: "\(all.prefix(2).formatted(.list(type: .and, width: .narrow))) and \(all.count - 2) more")
    }
}

/// What a Mac remembers of the digest, in digest.json, and shares with the other Macs through iCloud
/// Drive (Software Factory/Digest/<machine id>.json), so only one of them sends each day's.
struct DigestState: Codable, Sendable {
    /// The last digest: the day it was for, and the days it covered ("2026-10-28").
    struct Record: Codable, Hashable, Sendable {
        var day: String
        var from: String
        var through: String
        /// When it was sent; nil when there was nothing to say.
        var sent: Date?
        var machine: String?
    }

    /// A snoozed nudge: until when, and when that was decided, so the latest decision wins across Macs.
    struct Snooze: Codable, Hashable, Sendable {
        var until: Date
        var set: Date
    }

    var version = 1
    var record: Record?
    /// By nudge.
    var snoozed: [String: Snooze] = [:]

    /// The later record and the latest snoozes, from two Macs.
    mutating func merge(_ other: DigestState) {
        if let theirs = other.record, (record.map { theirs.day > $0.day } ?? true) { record = theirs }
        snoozed.merge(other.snoozed) { $0.set >= $1.set ? $0 : $1 }
    }
}
