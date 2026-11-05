import Foundation

/// Where everyone is from moment to moment: people walk tile by tile from the door to their seat,
/// between seats, and out again, around furniture and through doorways. With no way through they
/// fade out and in instead. `apply` takes the cast after each refresh or tick; `frame(at:)` says
/// where everyone is at any instant, without changing anything, for drawing.
nonisolated struct OfficeStage: Sendable {
    /// One step from tile to tile, and a fade in or out: the office's tween.
    static let step: TimeInterval = 0.4

    /// A walk: optionally fade out where they were (no route) or fade in at the start, then walk the
    /// path, then sit or leave.
    struct Plan: Hashable, Sendable {
        var start: Date
        var path: [Tile]
        /// Fades out at this tile first, and in at the path's start: there was no way to walk.
        var vanishFrom: Tile?
        var fadeIn = false
        var leaves = false

        private var walkStart: Date {
            start.addingTimeInterval((vanishFrom != nil ? OfficeStage.step : 0) + (fadeIn || vanishFrom != nil ? OfficeStage.step : 0))
        }

        var arrival: Date { walkStart.addingTimeInterval(Double(max(path.count - 1, 0)) * OfficeStage.step) }
        /// When it's over: seated, or gone.
        var end: Date { arrival.addingTimeInterval(leaves ? OfficeStage.step : 0) }
        var destination: Tile { path.last ?? vanishFrom ?? OfficeFloor.entrance }

        /// Where they are, which way they face, how opaque, and whether they're on the move.
        func position(at date: Date) -> (x: Double, y: Double, heading: Heading, opacity: Double, moving: Bool) {
            let t = date.timeIntervalSince(start)
            if let from = vanishFrom, t < OfficeStage.step {
                return (Double(from.x), Double(from.y), .front, 1 - max(0, t) / OfficeStage.step, false)
            }
            let first = path.first ?? destination
            let fadeEnd = walkStart.timeIntervalSince(start)
            if (fadeIn || vanishFrom != nil), t < fadeEnd {
                let into = t - (vanishFrom != nil ? OfficeStage.step : 0)
                return (Double(first.x), Double(first.y), .front, min(1, max(0, into) / OfficeStage.step), false)
            }
            let walked = date.timeIntervalSince(walkStart) / OfficeStage.step
            if walked < Double(path.count - 1) {
                let index = max(0, Int(walked))
                let fraction = walked - Double(index)
                let a = path[index], b = path[index + 1]
                return (Double(a.x) + Double(b.x - a.x) * fraction, Double(a.y) + Double(b.y - a.y) * fraction,
                        Heading(dx: b.x - a.x, dy: b.y - a.y), 1, true)
            }
            let last = destination
            let heading: Heading = path.count >= 2 ? Heading(dx: last.x - path[path.count - 2].x, dy: last.y - path[path.count - 2].y) : .front
            if leaves {
                let gone = date.timeIntervalSince(arrival) / OfficeStage.step
                return (Double(last.x), Double(last.y), heading, max(0, 1 - gone), false)
            }
            return (Double(last.x), Double(last.y), .front, 1, false)
        }

        /// The tile they're on or stepping onto: where a new walk starts from.
        func tile(at date: Date) -> Tile {
            if let from = vanishFrom, date.timeIntervalSince(start) < OfficeStage.step { return from }
            let walked = date.timeIntervalSince(walkStart) / OfficeStage.step
            guard walked > 0, !path.isEmpty else { return path.first ?? destination }
            return path[min(path.count - 1, Int(walked.rounded(.up)))]
        }
    }

    /// The way someone faces: front toward you (+x or +y), back away from you.
    enum Heading: Hashable, Sendable {
        case front, frontLeft, frontRight, backLeft, backRight

        init(dx: Int, dy: Int) {
            switch (dx, dy) {
            case (1, _): self = .frontRight
            case (_, 1): self = .frontLeft
            case (-1, _): self = .backLeft
            case (_, -1): self = .backRight
            default: self = .front
            }
        }

        var isBack: Bool { self == .backLeft || self == .backRight }
        /// Going left on screen: the sprite is mirrored.
        var isMirrored: Bool { self == .frontLeft || self == .backLeft }
    }

    struct Actor: Hashable, Sendable {
        var id: String
        var seat: Seat?
        var plan: Plan
    }

    /// Someone as drawn at one instant.
    struct Figure: Hashable, Sendable {
        var id: String
        var x: Double
        var y: Double
        var heading: Heading
        var opacity: Double
        var moving: Bool
        /// In their chair.
        var seated: Bool
        var seat: Seat?
    }

    private(set) var actors: [String: Actor] = [:]
    /// Until the first cast arrives, everyone is simply at their seat rather than walking in.
    private(set) var hasStarted = false
    let floor: OfficeFloor

    init(floor: OfficeFloor = .standard) {
        self.floor = floor
    }

    /// Brings everyone in line with the cast: newcomers walk in from the door (or, the first time,
    /// are simply at their seats), people with a new seat walk there, and people without one walk out.
    mutating func apply(_ cast: OfficeCast, now: Date) {
        let firstTime = !hasStarted
        hasStarted = true
        // Walks that are over: leavers go.
        actors = actors.filter { !($0.value.plan.leaves && now >= $0.value.plan.end) }

        for member in cast.members.values {
            let seat = member.seat
            if var actor = actors[member.id] {
                guard actor.seat != seat || (seat == nil && !actor.plan.leaves) else { continue }
                let from = actor.plan.tile(at: now)
                if let seat {
                    actor.plan = walk(from: from, to: OfficeFloor.chair(seat), now: now)
                } else {
                    actor.plan = walk(from: from, to: OfficeFloor.entrance, now: now, leaving: true)
                }
                actor.seat = seat
                actors[member.id] = actor
            } else if let seat {
                let chair = OfficeFloor.chair(seat)
                let plan = firstTime ? Plan(start: now, path: [chair], fadeIn: true)
                    : walk(from: OfficeFloor.entrance, to: chair, now: now, arriving: true)
                actors[member.id] = Actor(id: member.id, seat: seat, plan: plan)
            }
        }
        // People the cast has let go walk out.
        for (id, actor) in Array(actors) where cast.members[id] == nil && !actor.plan.leaves {
            var leaving = actor
            leaving.seat = nil
            leaving.plan = walk(from: actor.plan.tile(at: now), to: OfficeFloor.entrance, now: now, leaving: true)
            actors[id] = leaving
        }
    }

    /// A walk from one tile to another; a fade out and in when there's no way through.
    func walk(from: Tile, to: Tile, now: Date, arriving: Bool = false, leaving: Bool = false) -> Plan {
        if let path = floor.path(from: from, to: to) {
            return Plan(start: now, path: path, fadeIn: arriving, leaves: leaving)
        }
        if leaving { return Plan(start: now, path: [from], leaves: true) }
        return Plan(start: now, path: [to], vanishFrom: arriving ? nil : from, fadeIn: arriving)
    }

    /// Everyone at an instant, back to front isn't its job: the renderer sorts by depth.
    func frame(at date: Date) -> [Figure] {
        actors.values.compactMap { actor in
            let position = actor.plan.position(at: date)
            guard position.opacity > 0.01 else { return nil }
            let seated = !actor.plan.leaves && actor.seat != nil && date >= actor.plan.arrival
            return Figure(id: actor.id, x: position.x, y: position.y, heading: position.heading, opacity: position.opacity,
                          moving: position.moving, seated: seated, seat: actor.seat)
        }
    }

    /// Whether someone is in the office (or on their way in or out).
    func isPresent(_ id: String) -> Bool { actors[id] != nil }

    mutating func reset() {
        actors = [:]
        hasStarted = false
    }
}
