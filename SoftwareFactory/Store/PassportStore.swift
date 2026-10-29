import Foundation
import Observation
import OSLog

/// The Passport's numbers: what this Mac's transcripts, git history and App Store builds add up to,
/// with the other Macs' numbers from iCloud Drive. It reads every ten minutes, and when the Passport
/// opens. The first read takes a few seconds per gigabyte of transcripts; after that it reads only
/// what's new.
@MainActor
@Observable
final class PassportStore {
    static let shared = PassportStore()

    private(set) var ledger = PassportLedger()
    /// This Mac's days and the other Macs', by the projects on this board.
    private(set) var days: [ProjectDay] = []
    /// First commits, by project.
    private(set) var firstCommits: [String: Date] = [:]
    /// The other Macs whose numbers are in.
    private(set) var otherMacs: [String] = []
    private(set) var isReading = false
    private(set) var lastRead: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var localDays: [ProjectDay] = []
    @ObservationIgnored private var shares: [PassportShare] = []
    @ObservationIgnored private var keptDays = PassportStore.readKeptDays()
    @ObservationIgnored private let log = Logger(subsystem: "com.darrell.softwarefactory", category: "passport")

    private var fileURL: URL { ProjectStore.shared.dataDirectory.appending(path: "passport.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? ProjectStore.decoder.decode(PassportLedger.self, from: data) {
            ledger = saved
        }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Discovery goes first: it knows which folders are projects.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled, let self {
                await self.read()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Reads now, unless it read in the last minute.
    func readIfStale() {
        guard !isReading, (lastRead.map { Date.now.timeIntervalSince($0) > 60 } ?? true) else { return }
        Task { await read() }
    }

    func summary(_ period: PassportPeriod, now: Date) -> PassportSummary {
        let store = ProjectStore.shared
        let codes = store.projects.mapValues(\.code)
        return PassportSummary.make(period, now: now, days: days, releases: ledger.releases, builds: ledger.builds,
                                    firstCommits: firstCommits, codes: codes, recordedSince: recordedSince)
    }

    /// From when the record is whole: the first read, less the days Claude Code keeps transcripts
    /// (`cleanupPeriodDays` in ~/.claude/settings.json, 30 by default).
    var recordedSince: Date {
        (ledger.firstRead ?? .now).addingTimeInterval(-Double(keptDays) * 86_400)
    }

    private static func readKeptDays() -> Int {
        let settings = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/settings.json")
        return (try? Data(contentsOf: settings))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["cleanupPeriodDays"] as? Int } ?? 30
    }

    func read() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        let store = ProjectStore.shared
        let known = ledger.transcripts
        let roots = Array(Set(store.projects.values.filter { $0.isOnThisMac }.compactMap(\.path)))
        let since = Calendar.current.date(byAdding: .day, value: -62, to: .now) ?? .now
        let unknownFirsts = roots.filter { ledger.firstCommits[$0] == nil }
        let (transcripts, commits, firsts) = await Task.detached(priority: .utility) {
            (PassportReader.transcripts(known), PassportReader.commits(in: roots, since: since), PassportReader.firstCommits(in: unknownFirsts))
        }.value

        ledger.transcripts = transcripts
        ledger.firstRead = ledger.firstRead ?? .now
        keptDays = Self.readKeptDays()
        for (root, byDay) in commits {
            // Added to what was counted before: older days are past git's window now.
            for (day, hashes) in byDay {
                ledger.commits[root, default: [:]][day] = Array(Set(ledger.commits[root]?[day] ?? []).union(hashes)).sorted()
            }
        }
        ledger.firstCommits.merge(firsts) { old, _ in old }
        collectReleasesAndBuilds(from: store)
        save()

        localDays = makeLocalDays(store)
        if store.syncsWithOtherMacs, SyncFolder.isAvailable {
            let share = makeShare(store, since: since)
            let machineID = store.machineID
            shares = await Task.detached(priority: .utility) {
                try? SyncFolder.writeShared(share, in: "Stats", machineID: machineID)
                return SyncFolder.readShared(PassportShare.self, in: "Stats", excluding: machineID)
            }.value
        } else {
            shares = []
        }
        combine(store)
        lastRead = .now
    }

    // MARK: -

    /// Shipped reports and TestFlight builds, from the board (every Mac's), kept here for good.
    private func collectReleasesAndBuilds(from store: ProjectStore) {
        var releases = Dictionary(ledger.releases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var builds = Dictionary(ledger.builds.map { ("\($0.project)|\($0.number)", $0) }, uniquingKeysWith: { a, _ in a })
        for project in store.projects.values {
            for event in project.events where event.isRelease {
                releases[event.id] = releases[event.id] ?? Release(id: event.id, project: project.id, date: event.date, title: event.title)
            }
            for upload in project.appStore?.uploads ?? [] {
                let key = "\(project.id)|\(upload.number)"
                if upload.uploaded < builds[key]?.date ?? .distantFuture {
                    builds[key] = BuildMark(project: project.id, number: upload.number, date: upload.uploaded)
                }
            }
        }
        let cutoff = Date.now.addingTimeInterval(-400 * 86_400)
        ledger.releases = releases.values.filter { $0.date > cutoff }.sorted { $0.date < $1.date }
        ledger.builds = builds.values.filter { $0.date > cutoff }.sorted { $0.date < $1.date }
    }

    /// This Mac's transcripts and commits, by project and day.
    private func makeLocalDays(_ store: ProjectStore) -> [ProjectDay] {
        var ids: [String: String] = [:]
        func project(_ root: String?) -> String {
            guard let root else { return "" }
            if let id = ids[root] { return id }
            let id = store.projectID(forPath: root, create: false) ?? ""
            ids[root] = id
            return id
        }
        var days: [String: ProjectDay] = [:]
        for tally in ledger.transcripts.values {
            let id = project(tally.root)
            for (day, usage) in tally.days {
                days["\(day)|\(id)", default: ProjectDay(day: day, project: id)].usage += usage
                if usage.turns > 0, !tally.isAgent { days["\(day)|\(id)"]?.sessions.insert(String(tally.session.prefix(8))) }
            }
        }
        for (root, byDay) in ledger.commits {
            let id = project(root)
            for (day, hashes) in byDay {
                days["\(day)|\(id)", default: ProjectDay(day: day, project: id)].commits.formUnion(hashes)
            }
        }
        firstCommits = [:]
        for (root, date) in ledger.firstCommits { firstCommits[project(root)] = date }
        firstCommits[""] = nil
        return Array(days.values)
    }

    private func makeShare(_ store: ProjectStore, since: Date) -> PassportShare {
        var keys = DayKeys()
        let first = keys.key(for: since)
        let recent = localDays.filter { $0.day >= first }
        var refs: [String: PassportShare.ProjectRef] = [:]
        for id in Set(recent.map(\.project)).union(firstCommits.keys) {
            guard let project = store[id] else { continue }
            refs[id] = .init(name: project.name, repo: project.repo)
        }
        return PassportShare(machineID: store.machineID, machineName: store.machineName, updated: .now,
                             projects: refs, days: recent, firstCommits: firstCommits)
    }

    /// This Mac's days with the other Macs', their projects matched to the ones here.
    private func combine(_ store: ProjectStore) {
        var all = Dictionary(localDays.map { ("\($0.day)|\($0.project)", $0) }, uniquingKeysWith: { a, _ in a })
        for share in shares {
            func local(_ id: String) -> String {
                guard let ref = share.projects[id] else { return id }
                return store.projectID(matching: id, name: ref.name, repo: ref.repo)
            }
            for theirs in share.days {
                let id = local(theirs.project)
                let key = "\(theirs.day)|\(id)"
                var day = all[key] ?? ProjectDay(day: theirs.day, project: id)
                day.usage += theirs.usage
                day.sessions.formUnion(theirs.sessions)
                // A repository cloned on both Macs: its commits once.
                day.commits.formUnion(theirs.commits)
                all[key] = day
            }
            for (id, date) in share.firstCommits {
                let id = local(id)
                firstCommits[id] = min(firstCommits[id] ?? date, date)
            }
        }
        days = Array(all.values)
        otherMacs = shares.map(\.machineName).sorted()
    }

    private func save() {
        let ledger = ledger
        let url = fileURL
        Task.detached(priority: .utility) { [log] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = JSONDates.encoding
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(ledger).write(to: url, options: .atomic)
            } catch {
                log.error("Couldn't save the Passport: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension Event {
    /// A Shipped report: `factory done`, or an app going live.
    var isRelease: Bool { state == .done && symbol == ProjectState.done.symbol && detail != "Step done" }
}

/// The reading itself, off the main thread.
nonisolated enum PassportReader {
    /// Every transcript, read from where it was left: sessions, and their subagents' for tokens.
    static func transcripts(_ known: [String: TranscriptTally]) -> [String: TranscriptTally] {
        var tallies = known
        let fm = FileManager.default
        func contents(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        }
        func read(_ url: URL, session: String, agent: Bool) {
            var tally = tallies[url.path] ?? TranscriptTally(session: session, root: nil, isAgent: agent)
            if tally.root == nil, let cwd = Discovery.workingDirectory(in: url) { tally.root = ProjectPath.root(for: cwd) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            guard size != tally.offset || tallies[url.path] == nil else { return }
            tally.read(url)
            tallies[url.path] = tally
        }
        for folder in contents(Discovery.claudeProjects) {
            for item in contents(folder) {
                if item.pathExtension == "jsonl" {
                    read(item, session: item.deletingPathExtension().lastPathComponent, agent: false)
                } else {
                    for agent in contents(item.appending(path: "subagents")) where agent.pathExtension == "jsonl" {
                        read(agent, session: item.lastPathComponent, agent: true)
                    }
                }
            }
        }
        return tallies
    }

    /// Each folder's commits since a date, on every branch, by day.
    static func commits(in roots: [String], since: Date) -> [String: [String: [String]]] {
        var found: [String: [String: [String]]] = [:]
        var keys = DayKeys()
        let after = since.formatted(.iso8601)
        for root in roots where FileManager.default.fileExists(atPath: root + "/.git") {
            guard let output = Discovery.run("/usr/bin/git", ["-C", root, "log", "--all", "--no-merges", "--since=\(after)", "--format=%H %aI"]) else { continue }
            var byDay: [String: [String]] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let date = try? Date(String(parts[1]), strategy: .iso8601) else { continue }
                byDay[keys.key(for: date), default: []].append(String(parts[0].prefix(12)))
            }
            found[root] = byDay
        }
        return found
    }

    /// When each folder's repository began: its first commit.
    static func firstCommits(in roots: [String]) -> [String: Date] {
        var found: [String: Date] = [:]
        for root in roots where FileManager.default.fileExists(atPath: root + "/.git") {
            guard let output = Discovery.run("/usr/bin/git", ["-C", root, "log", "--max-parents=0", "--format=%aI", "HEAD"]) else { continue }
            let dates = output.split(separator: "\n").compactMap { try? Date(String($0), strategy: .iso8601) }
            if let first = dates.min() { found[root] = first }
        }
        return found
    }
}
