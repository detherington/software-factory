import Foundation

/// One project's day: Claude's time, turns and tokens there, and its sessions and commits.
struct ProjectDay: Codable, Hashable, Sendable {
    /// "2026-10-28".
    var day: String
    /// The project's id on the Mac that counted it; "" for folders that aren't projects.
    var project: String
    var usage = Usage()
    /// Sessions with a turn that day (their ids' first eight characters).
    var sessions: Set<String> = []
    /// Commits made that day (their hashes' first twelve characters).
    var commits: Set<String> = []
}

/// A release: a Shipped report, from `factory done` or an app going live.
struct Release: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var project: String
    var date: Date
    var title: String
}

/// A TestFlight build: one number, whatever its platforms.
struct BuildMark: Codable, Hashable, Sendable {
    var project: String
    var number: String
    var date: Date
}

/// What this Mac has counted, kept in passport.json. It outlasts the transcripts: Claude Code deletes
/// those after a month.
struct PassportLedger: Codable, Sendable {
    var version = 1
    /// By transcript path.
    var transcripts: [String: TranscriptTally] = [:]
    /// Commit hashes by project folder, then day.
    var commits: [String: [String: [String]]] = [:]
    /// Each project folder's first commit.
    var firstCommits: [String: Date] = [:]
    var releases: [Release] = []
    var builds: [BuildMark] = []
    /// The first read: the record is whole from a month before it (what Claude Code still kept).
    var firstRead: Date?
}

/// A Mac's numbers as it shares them, in iCloud Drive/Software Factory/Stats/<machine id>.json.
struct PassportShare: Codable, Sendable {
    struct ProjectRef: Codable, Sendable {
        var name: String
        var repo: String?
    }

    var version = 1
    var machineID: String
    var machineName: String
    var updated: Date
    /// Its projects' names and repositories, to find the same project on another Mac.
    var projects: [String: ProjectRef]
    /// The last two months.
    var days: [ProjectDay]
    var firstCommits: [String: Date]
}

enum PassportPeriod: String, CaseIterable, Identifiable, Sendable {
    case thisWeek = "this-week"
    case lastWeek = "last-week"
    case month

    var id: Self { self }

    var title: String {
        switch self {
        case .thisWeek: String(localized: "This Week")
        case .lastWeek: String(localized: "Last Week")
        case .month: String(localized: "30 Days")
        }
    }

    /// The start of each of its days, oldest first. A week runs as the calendar's does.
    func days(at now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let first: Date
        let count: Int
        switch self {
        case .thisWeek, .lastWeek:
            let week = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            first = self == .thisWeek ? week : calendar.date(byAdding: .day, value: -7, to: week) ?? week
            count = 7
        case .month:
            first = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            count = 30
        }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// The days of the period before: last week for this one, the 30 days before for a month.
    func previousDays(at now: Date, calendar: Calendar = .current) -> [Date] {
        let days = days(at: now, calendar: calendar)
        return days.compactMap { calendar.date(byAdding: .day, value: -days.count, to: $0) }
    }
}

/// A period's numbers, ready to show.
struct PassportSummary: Encodable, Sendable {
    struct Day: Identifiable, Encodable, Sendable {
        var id: String
        var date: Date
        var usage: Usage
        var commits: Int
        var builds: Int
        var releases: Int
        var isFuture: Bool
    }

    struct Row: Identifiable, Encodable, Sendable {
        /// A project's id; "" for folders that aren't projects.
        var id: String
        var usage = Usage()
        var sessions = 0
        var commits = 0
        var builds = 0
        var releases = 0
    }

    /// A milestone, shown like a passport stamp.
    struct Stamp: Identifiable, Encodable, Sendable {
        var id: String
        var label: String
        var value: String
        var caption: String
        var detail: String?
        var swatch: Swatch
        var project: String?
    }

    var days: [Day]
    var total: Usage
    var sessions: Int
    var commits: Int
    var builds: Int
    var releases: [Release]
    /// Projects with anything to show, busiest first.
    var rows: [Row]
    var stamps: [Stamp]
    /// Working time in the period before, to compare; nil when the record doesn't reach back that
    /// far (Claude Code had deleted those transcripts before the board read them).
    var previousSeconds: Double?

    static func make(_ period: PassportPeriod, now: Date, days projectDays: [ProjectDay], releases: [Release],
                     builds: [BuildMark], firstCommits: [String: Date], codes: [String: String], recordedSince: Date) -> PassportSummary {
        make(dates: period.days(at: now), previous: period.previousDays(at: now), now: now, days: projectDays, releases: releases,
             builds: builds, firstCommits: firstCommits, codes: codes, recordedSince: recordedSince)
    }

    /// Any run of days (the digest's), compared with `previous` when there are any.
    static func make(dates: [Date], previous previousDates: [Date], now: Date, days projectDays: [ProjectDay], releases: [Release],
                     builds: [BuildMark], firstCommits: [String: Date], codes: [String: String], recordedSince: Date) -> PassportSummary {
        var keys = DayKeys()
        let dayKeys = dates.map { keys.key(for: $0) }
        let inPeriod = Set(dayKeys)
        let previous = Set(previousDates.map { keys.key(for: $0) })
        let today = keys.key(for: now)

        let current = projectDays.filter { inPeriod.contains($0.day) }
        let periodReleases = releases.filter { inPeriod.contains(keys.key(for: $0.date)) }.sorted { $0.date > $1.date }
        let periodBuilds = builds.filter { inPeriod.contains(keys.key(for: $0.date)) }

        var byDay: [String: Day] = [:]
        for (date, key) in zip(dates, dayKeys) {
            byDay[key] = Day(id: key, date: date, usage: Usage(), commits: 0, builds: 0, releases: 0, isFuture: key > today)
        }
        var rows: [String: Row] = [:]
        var sessions: Set<String> = []
        var commits: Set<String> = []
        var rowSessions: [String: Set<String>] = [:]
        var rowCommits: [String: Set<String>] = [:]
        for item in current {
            byDay[item.day]?.usage += item.usage
            byDay[item.day]?.commits += item.commits.count
            rows[item.project, default: Row(id: item.project)].usage += item.usage
            rowSessions[item.project, default: []].formUnion(item.sessions)
            rowCommits[item.project, default: []].formUnion(item.commits)
            sessions.formUnion(item.sessions)
            commits.formUnion(item.commits)
        }
        for (project, set) in rowSessions { rows[project]?.sessions = set.count }
        for (project, set) in rowCommits { rows[project]?.commits = set.count }
        for build in periodBuilds {
            byDay[keys.key(for: build.date)]?.builds += 1
            rows[build.project, default: Row(id: build.project)].builds += 1
        }
        for release in periodReleases {
            byDay[keys.key(for: release.date)]?.releases += 1
            rows[release.project, default: Row(id: release.project)].releases += 1
        }

        let days = dayKeys.compactMap { byDay[$0] }
        let total = days.reduce(Usage()) { $0 + $1.usage }
        let sorted = rows.values
            .filter { $0.usage.seconds >= 60 || $0.commits > 0 || $0.builds > 0 || $0.releases > 0 }
            .sorted { ($0.usage.seconds, $0.commits, $0.id) > ($1.usage.seconds, $1.commits, $1.id) }
        let previousSeconds: Double? = (previous.min() ?? "") >= keys.key(for: recordedSince)
            ? projectDays.filter { previous.contains($0.day) }.reduce(0) { $0 + $1.usage.seconds }
            : nil

        // Stamps: releases, new projects, then the period's records.
        var stamps: [Stamp] = []
        let short = Date.FormatStyle().month(.abbreviated).day()
        func code(_ id: String) -> String { codes[id] ?? (id.isEmpty ? "—" : id.prefix(3).uppercased()) }
        for release in periodReleases.prefix(6) {
            stamps.append(Stamp(id: "release-\(release.id)", label: String(localized: "Shipped"), value: code(release.project),
                                caption: release.date.formatted(short), detail: release.title, swatch: .mint, project: release.project))
        }
        for (project, date) in firstCommits.sorted(by: { $0.value < $1.value }).filter({ inPeriod.contains(keys.key(for: $0.value)) }).prefix(6) {
            stamps.append(Stamp(id: "new-\(project)", label: String(localized: "New project"), value: code(project),
                                caption: date.formatted(short), detail: String(localized: "First commit"), swatch: .violet, project: project))
        }
        if let busiest = days.max(by: { $0.usage.seconds < $1.usage.seconds }), busiest.usage.seconds >= 1800 {
            stamps.append(Stamp(id: "busiest", label: String(localized: "Busiest day"), value: Formats.hours(busiest.usage.seconds) + " h",
                                caption: busiest.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                detail: String(localized: "\(busiest.usage.turns) turns"), swatch: .amber))
        }
        if let longest = current.max(by: { $0.usage.longestTurn < $1.usage.longestTurn }), longest.usage.longestTurn >= 20 * 60,
           let date = byDay[longest.day]?.date {
            stamps.append(Stamp(id: "longest", label: String(localized: "Longest turn"), value: Formats.duration(longest.usage.longestTurn),
                                caption: "\(code(longest.project)) · \(date.formatted(short))",
                                detail: String(localized: "Claude's longest single turn"), swatch: .orchid, project: longest.project))
        }
        var run = 0
        var best = (length: 0, end: 0)
        for (index, day) in days.enumerated() {
            run = day.usage.seconds > 0 ? run + 1 : 0
            if run > best.length { best = (run, index) }
        }
        if best.length >= 3 {
            let first = days[best.end - best.length + 1].date
            let last = days[best.end].date
            stamps.append(Stamp(id: "streak", label: String(localized: "In a row"), value: String(localized: "\(best.length) days"),
                                caption: "\(first.formatted(short)) – \(last.formatted(short))", swatch: .lime))
        }
        if let most = sorted.max(by: { $0.builds < $1.builds }), most.builds >= 3 {
            stamps.append(Stamp(id: "builds", label: String(localized: "TestFlight"), value: String(localized: "\(most.builds) builds"),
                                caption: code(most.id), swatch: .sky, project: most.id))
        }

        return PassportSummary(days: days, total: total, sessions: sessions.count, commits: commits.count, builds: periodBuilds.count,
                               releases: periodReleases, rows: sorted, stamps: stamps, previousSeconds: previousSeconds)
    }
}
