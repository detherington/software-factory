import Foundation

/// How one project's records from several Macs become one card.
///
/// - What a project is (name, code, folder, kind): this Mac's record first.
/// - What was reported (state, task, note, milestone, progress, steps, version): the latest report
///   wins, whichever Mac it was made on.
/// - Sessions and the timeline: all of them, each labeled with its Mac. Anything another Mac heard
///   from this one over the network is left out, since this Mac has it already.
/// - The latest commit and sign of life: the newest.
nonisolated enum BoardMerge {
    static func combine(_ mine: Project?, _ theirs: [(project: Project, machine: String)], thisMac: String) -> Project? {
        let tagged = theirs.map { item -> Project in
            var project = item.project
            project.sessions = project.sessions
                .filter { $0.machine != thisMac }
                .map { session in
                    var session = session
                    session.machine = session.machine ?? item.machine
                    return session
                }
            project.events = project.events
                .filter { $0.machine != thisMac }
                .map { event in
                    var event = event
                    event.machine = event.machine ?? item.machine
                    return event
                }
            return project
        }
        guard var merged = mine ?? tagged.first else { return nil }
        let others = mine == nil ? Array(tagged.dropFirst()) : tagged
        guard !others.isEmpty else { return merged }

        for other in others {
            if (other.lastReport ?? .distantPast) > (merged.lastReport ?? .distantPast) {
                merged.reported = other.reported
                merged.reportedAt = other.reportedAt
                merged.lastReport = other.lastReport
                merged.task = other.task
                merged.note = other.note
                merged.milestone = other.milestone
                merged.progress = other.progress
                merged.steps = other.steps
                merged.version = other.version ?? merged.version
            }
            merged.summary = merged.summary ?? other.summary
            merged.readme = merged.readme ?? other.readme
            merged.kind = merged.kind ?? other.kind
            merged.detectedKind = merged.detectedKind ?? other.detectedKind
            merged.symbol = merged.symbol ?? other.symbol
            merged.repo = merged.repo ?? other.repo
            merged.branch = merged.branch ?? other.branch
            merged.links.merge(other.links) { mine, _ in mine }

            // The same session can arrive twice (reported over the network and shared): keep the newer.
            var sessions = Dictionary(merged.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for session in other.sessions where session.updated > (sessions[session.id]?.updated ?? .distantPast) {
                sessions[session.id] = session
            }
            merged.sessions = Array(sessions.values)

            let known = Set(merged.events.map(\.id))
            let knownCommits = Set(merged.events.compactMap(\.ref))
            merged.events += other.events.filter { !known.contains($0.id) && !($0.ref.map(knownCommits.contains) ?? false) }

            if let commit = other.lastCommit, commit.date > (merged.lastCommit?.date ?? .distantPast) { merged.lastCommit = commit }
            merged.lastActivity = max(merged.lastActivity, other.lastActivity)
        }
        merged.events.sort { $0.date > $1.date }
        if merged.events.count > 200 { merged.events.removeLast(merged.events.count - 200) }
        return merged
    }
}
