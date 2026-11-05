import Foundation

/// The office's people over time: what each one shows, where they sit and what they're called,
/// smoothed so nothing flickers. Feed it each refresh's `OfficeState` with `update`, and call `tick`
/// in between so held states move on when their time is up.
///
/// - A shown state lasts its minimum time (idle 4 s, typing 8 s, a balloon 6 s, arms up 20 s) before
///   the next one shows.
/// - Back to idle needs two refreshes in a row saying so.
/// - Someone who drops out of the data stays 15 s, then goes.
/// - Seats are sticky: a team keeps its zone, a lead their office, everyone their desk. When a zone is
///   full, the most active keep the desks and the rest count as "+N".
nonisolated struct OfficeCast: Sendable {
    struct Member: Hashable, Sendable {
        /// The latest from the data.
        var person: OfficePerson
        var name: String
        var shown: PersonState
        var shownSince: Date
        /// What the balloon says while talking, held as long as the balloon.
        var label: String?
        var labelSince: Date
        /// Refreshes in a row that said idle.
        var idleVotes = 0
        /// When they dropped out of the data.
        var leftAt: Date?
        var seat: Seat?

        var id: String { person.id }
        var isLeaving: Bool { leftAt != nil }
    }

    static let leaveAfter: TimeInterval = 15

    private(set) var members: [String: Member] = [:]
    /// Which team has each zone of the open space.
    private(set) var zones: [String?] = Array(repeating: nil, count: OfficeFloor.zones)
    /// Which team's lead has each team office.
    private(set) var rooms: [String?] = Array(repeating: nil, count: OfficeFloor.teamRooms)
    /// The team whose lead has the Lead office.
    private(set) var leadTeam: String?
    private var leadVote: (team: String?, count: Int) = (nil, 0)
    private(set) var teamTitles: [String: String] = [:]
    /// Teams with no zone free.
    private(set) var hiddenTeams: [String] = []

    var isEmpty: Bool { members.isEmpty }

    // MARK: Feeding it

    mutating func update(_ state: OfficeState, now: Date) {
        let seen = Set(state.people.map(\.id))
        for zone in state.zones where zone.kind == .open { if let team = zone.team { teamTitles[team] = zone.title } }
        for person in state.people {
            if var member = members[person.id] {
                member.person = person
                member.leftAt = nil
                if person.state == .idle, member.shown != .idle {
                    member.idleVotes += 1
                } else {
                    member.idleVotes = 0
                }
                members[person.id] = member
            } else {
                let taken = Set(members.values.map(\.name))
                let name = person.name ?? OfficeNames.name(for: person.id, avoiding: taken)
                members[person.id] = Member(person: person, name: name, shown: person.state, shownSince: now,
                                            label: person.label, labelSince: now)
            }
        }
        for id in members.keys where !seen.contains(id) && members[id]?.leftAt == nil {
            members[id]?.leftAt = now
        }

        // The Lead office changes hands after two refreshes in a row, or at once if its team has gone.
        let wanted = state.leadTeam
        if wanted != leadTeam {
            leadVote = leadVote.team == wanted ? (wanted, leadVote.count + 1) : (wanted, 1)
            let present = Set(members.values.filter { !$0.isLeaving }.compactMap(\.person.team))
            if leadTeam == nil || !present.contains(leadTeam!) || leadVote.count >= 2 {
                leadTeam = wanted
                leadVote = (nil, 0)
            }
        } else {
            leadVote = (nil, 0)
        }
        tick(now: now)
    }

    /// Moves held states on, lets leavers go, and seats everyone.
    mutating func tick(now: Date) {
        for id in Array(members.keys) {
            guard var member = members[id] else { continue }
            if let left = member.leftAt, now.timeIntervalSince(left) >= Self.leaveAfter {
                members[id] = nil
                continue
            }
            var wanted = member.person.state
            // Back to idle only after two refreshes in a row; leavers keep what they showed.
            if member.isLeaving || (wanted == .idle && member.shown != .idle && member.idleVotes < 2) { wanted = member.shown }
            if wanted != member.shown, now.timeIntervalSince(member.shownSince) >= member.shown.minimumTime {
                member.shown = wanted
                member.shownSince = now
                member.label = member.person.label
                member.labelSince = now
            } else if wanted == member.shown, member.shown == .talking, member.person.label != member.label,
                      member.person.label != nil, now.timeIntervalSince(member.labelSince) >= PersonState.talking.minimumTime {
                member.label = member.person.label
                member.labelSince = now
            }
            members[id] = member
        }
        seat()
    }

    // MARK: Seats

    private mutating func seat() {
        // Teams by their latest sign of life; the Lead's team first, so it always has a zone.
        var latest: [String: Date] = [:]
        for member in members.values {
            guard let team = member.person.team else { continue }
            latest[team] = max(latest[team] ?? .distantPast, member.person.activity)
        }
        let teams = latest.keys.sorted { a, b in
            if (a == leadTeam) != (b == leadTeam) { return a == leadTeam }
            return latest[a]! != latest[b]! ? latest[a]! > latest[b]! : a < b
        }
        for index in zones.indices where zones[index].map({ latest[$0] == nil }) ?? false { zones[index] = nil }
        var unzoned: [String] = []
        for team in teams where !zones.contains(team) {
            if let free = zones.firstIndex(of: nil) { zones[free] = team } else { unzoned.append(team) }
        }
        // A Lead's team without a zone takes the quietest team's.
        if let lead = leadTeam, unzoned.contains(lead), let quietest = zones.indices.min(by: { latest[zones[$0]!]! < latest[zones[$1]!]! }) {
            unzoned.append(zones[quietest]!)
            zones[quietest] = lead
            unzoned.removeAll { $0 == lead }
        }
        hiddenTeams = unzoned

        // Team offices for every zoned team but the Lead's.
        let officeTeams = zones.compactMap { $0 }.filter { $0 != leadTeam }
        for index in rooms.indices where rooms[index].map({ !officeTeams.contains($0) }) ?? false { rooms[index] = nil }
        for team in officeTeams where !rooms.contains(team) {
            if let free = rooms.firstIndex(of: nil) { rooms[free] = team }
        }

        // Offices.
        for id in Array(members.keys) {
            guard let member = members[id] else { continue }
            switch member.person.role {
            case .owner:
                members[id]?.seat = member.shown == .away ? nil : .owner
            case .lead:
                if let team = member.person.team, team == leadTeam {
                    members[id]?.seat = .lead
                } else if let team = member.person.team, let room = rooms.firstIndex(of: team) {
                    members[id]?.seat = .room(room)
                } else {
                    members[id]?.seat = nil
                }
            default:
                // A desk seat stays only in its team's zone.
                if case .desk(let zone, _)? = member.seat, zones[zone] == member.person.team { break }
                members[id]?.seat = nil
            }
        }
        // Two leads can't share an office: a lead on its way out keeps it, the new one waits.
        var held: Set<Seat> = []
        for member in members.values.sorted(by: { ($0.isLeaving ? 0 : 1, $0.id) < ($1.isLeaving ? 0 : 1, $1.id) }) {
            guard let seat = member.seat, OfficeFloor.room(of: seat) != nil else { continue }
            if held.contains(seat) { members[member.id]?.seat = nil } else { held.insert(seat) }
        }

        // Desks: the most active keep them.
        for (zone, team) in zones.enumerated() {
            guard let team else { continue }
            let crew = members.values.filter { $0.person.team == team && $0.person.role != .lead && $0.person.role != .owner }
            var taken: [Int: String] = [:]
            for member in crew {
                if case .desk(_, let index)? = member.seat { taken[index] = member.id }
            }
            let waiting = crew.filter { $0.seat == nil && !$0.isLeaving }
                .sorted { Self.rank($0) > Self.rank($1) }
            for member in waiting {
                if let free = (0..<OfficeFloor.desksPerZone).first(where: { taken[$0] == nil }) {
                    taken[free] = member.id
                    members[member.id]?.seat = .desk(zone: zone, index: free)
                    continue
                }
                // Full: the quietest seated person gives way, only to someone busier in kind.
                let seated = taken.compactMap { index, id in members[id].map { (index, $0) } }
                guard let (index, quietest) = seated.min(by: { Self.rank($0.1) < Self.rank($1.1) }),
                      !quietest.isLeaving, member.shown.activity > quietest.shown.activity else { continue }
                members[quietest.id]?.seat = nil
                taken[index] = member.id
                members[member.id]?.seat = .desk(zone: zone, index: index)
            }
        }
    }

    /// Who's busier: their kind of state, then their latest sign of life.
    private static func rank(_ member: Member) -> (Int, Date, String) {
        (member.shown.activity, member.person.activity, member.id)
    }

    // MARK: Reading

    /// People who count: everyone but you, leavers included until they go.
    var staff: [Member] { members.values.filter { $0.person.role != .owner } }
    var owner: Member? { members["owner"] }

    /// People in a zone's team with no desk: its "+N".
    func overflow(zone: Int) -> Int {
        guard let team = zones[zone] else { return 0 }
        return members.values.filter { $0.person.team == team && $0.seat == nil && !$0.isLeaving
            && $0.person.role != .lead && $0.person.role != .owner }.count
    }

    func zone(of team: String) -> Int? { zones.firstIndex(of: team) }
    func room(of team: String) -> Int? { rooms.firstIndex(of: team) }

    /// The name on a team's door or zone: its project's name.
    func title(of team: String?) -> String? { team.flatMap { teamTitles[$0] } }

    func name(of id: String) -> String? {
        id == "owner" ? owner?.name : members[id]?.name
    }
}
