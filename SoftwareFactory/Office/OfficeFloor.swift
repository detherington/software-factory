import Foundation

/// A floor tile: x runs along the back wall with the offices, y from the back toward you.
nonisolated struct Tile: Hashable, Sendable, CustomStringConvertible {
    var x: Int
    var y: Int

    init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    var neighbors: [Tile] { [Tile(x + 1, y), Tile(x - 1, y), Tile(x, y + 1), Tile(x, y - 1)] }
    var description: String { "(\(x),\(y))" }
}

/// Where someone sits.
nonisolated enum Seat: Hashable, Sendable {
    case owner
    case lead
    /// A team lead's office, 0 to 3.
    case room(Int)
    /// A desk in the open space: the zone's column (0 to 4) and the desk (0 to 5).
    case desk(zone: Int, index: Int)
}

/// The office's floor plan, fixed so nothing jumps as teams come and go:
///
/// - The back row (y 0–3) is six closed offices, four tiles wide, with glass fronts and a door each:
///   Owner, Lead, then four team leads' offices.
/// - A corridor (y 4–5) runs the full width. You come in by the door in the back-left wall.
/// - The open space (y 6–12) is five team zones, four tiles wide, each two rows of three desks with
///   the chairs behind them, so everyone faces you. The zone's name is painted on the front skirting.
/// - The server room is the open space's right end (x 20–23), with two rows of racks.
nonisolated struct OfficeFloor: Sendable {
    enum Furniture: Hashable, Sendable {
        case desk, chair, plant, cabinet, cooler, sofa
        /// A rack of four units, numbered from 0.
        case rack(Int)
    }

    static let width = 24
    static let depth = 13
    static let roomWidth = 4
    static let roomDepth = 4
    static let rooms = 6
    static let teamRooms = 4
    static let corridor = 4...5
    static let openStart = 6
    static let zoneWidth = 4
    static let zones = 5
    static let desksPerZone = 6
    static let serverStart = 20
    static let racks = 6
    static let unitsPerRack = 4
    /// Inside the door in the back-left wall: where people come in and go.
    static let entrance = Tile(0, 5)

    let furniture: [Tile: Furniture]
    /// Walls between neighboring tiles, each pair in both directions.
    let walls: Set<Wall>

    struct Wall: Hashable, Sendable {
        var a: Tile
        var b: Tile
    }

    enum Region: Hashable, Sendable {
        /// Room 0 is the owner's, 1 the Lead's, 2–5 the team leads'.
        case room(Int)
        case corridor
        case zone(Int)
        case servers
    }

    static let standard = OfficeFloor()

    init() {
        var furniture: [Tile: Furniture] = [:]
        var walls: Set<Wall> = []
        func wall(_ a: Tile, _ b: Tile) {
            walls.insert(Wall(a: a, b: b))
            walls.insert(Wall(a: b, b: a))
        }
        for room in 0..<Self.rooms {
            let x0 = room * Self.roomWidth
            // The desk at the back, so the sign over the door never hides whoever sits there.
            furniture[Tile(x0 + 1, 1)] = .desk
            furniture[Tile(x0 + 1, 0)] = .chair
            furniture[Tile(x0 + 3, 0)] = .plant
            furniture[Tile(x0, 0)] = .cabinet
            if room == 0 { furniture[Tile(x0, 2)] = .sofa }
            for y in 0..<Self.roomDepth where room > 0 { wall(Tile(x0 - 1, y), Tile(x0, y)) }
            // The glass front, with its door.
            for x in x0..<(x0 + Self.roomWidth) where x != Self.door(room: room).x {
                wall(Tile(x, Self.roomDepth - 1), Tile(x, Self.roomDepth))
            }
        }
        furniture[Tile(11, 4)] = .cooler
        furniture[Tile(23, 4)] = .plant
        for zone in 0..<Self.zones {
            for index in 0..<Self.desksPerZone {
                let chair = Self.chair(.desk(zone: zone, index: index))
                furniture[chair] = .chair
                furniture[Tile(chair.x, chair.y + 1)] = .desk
            }
        }
        for rack in 0..<Self.racks {
            furniture[Self.rackTile(rack)] = .rack(rack)
        }
        furniture[Tile(23, 12)] = .plant
        // The server room: glass toward the open space, a wall with a door to the corridor.
        for y in Self.openStart..<Self.depth { wall(Tile(Self.serverStart - 1, y), Tile(Self.serverStart, y)) }
        for x in Self.serverStart..<Self.width where x != Self.serverDoor.x { wall(Tile(x, Self.openStart - 1), Tile(x, Self.openStart)) }
        self.furniture = furniture
        self.walls = walls
    }

    /// A floor with other furniture or walls: for tests.
    init(furniture: [Tile: Furniture], walls: Set<Wall>) {
        self.furniture = furniture
        self.walls = walls
    }

    // MARK: Places

    /// The door in a room's glass front: the tile inside it.
    static func door(room: Int) -> Tile { Tile(room * roomWidth + 2, roomDepth - 1) }
    static let serverDoor = Tile(21, openStart)

    static func room(of seat: Seat) -> Int? {
        switch seat {
        case .owner: 0
        case .lead: 1
        case .room(let index): 2 + index
        case .desk: nil
        }
    }

    /// The chair a seat is: everyone sits facing you, the desk in front of them.
    static func chair(_ seat: Seat) -> Tile {
        switch seat {
        case .owner, .lead, .room:
            return Tile(room(of: seat)! * roomWidth + 1, 0)
        case .desk(let zone, let index):
            return Tile(zone * zoneWidth + index % 3, index < 3 ? 7 : 10)
        }
    }

    static func rackTile(_ rack: Int) -> Tile { Tile(serverStart + rack % 3, rack < 3 ? 7 : 10) }

    static func region(of tile: Tile) -> Region? {
        guard contains(tile) else { return nil }
        if tile.y < roomDepth { return .room(tile.x / roomWidth) }
        if corridor.contains(tile.y) { return .corridor }
        if tile.x >= serverStart { return .servers }
        return .zone(tile.x / zoneWidth)
    }

    static func contains(_ tile: Tile) -> Bool { tile.x >= 0 && tile.x < width && tile.y >= 0 && tile.y < depth }

    func isOpen(_ tile: Tile) -> Bool { Self.contains(tile) && furniture[tile] == nil }

    func canStep(from a: Tile, to b: Tile) -> Bool { !walls.contains(Wall(a: a, b: b)) }

    // MARK: Walking

    /// The shortest walk from one tile to another, tile by tile, around furniture and through
    /// doorways: both ends included. The ends may be furniture (a chair); nothing else on the way
    /// may. Nil when there's no way through.
    func path(from start: Tile, to goal: Tile) -> [Tile]? {
        guard Self.contains(start), Self.contains(goal) else { return nil }
        if start == goal { return [start] }
        var previous: [Tile: Tile] = [start: start]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let tile = queue[head]
            head += 1
            // Straight on first, so walks turn as little as they can.
            var next = tile.neighbors
            if let before = previous[tile], before != tile,
               let ahead = next.firstIndex(of: Tile(2 * tile.x - before.x, 2 * tile.y - before.y)) {
                next.swapAt(0, ahead)
            }
            for step in next where previous[step] == nil && Self.contains(step) && canStep(from: tile, to: step) {
                guard step == goal || isOpen(step) else { continue }
                previous[step] = tile
                if step == goal {
                    var path = [goal]
                    var at = goal
                    while at != start {
                        at = previous[at]!
                        path.append(at)
                    }
                    return path.reversed()
                }
                queue.append(step)
            }
        }
        return nil
    }
}
