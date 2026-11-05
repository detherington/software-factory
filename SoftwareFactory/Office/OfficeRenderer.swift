import CoreGraphics
import SwiftUI

/// The office's picture, in pixels: 2:1 isometric tiles 32 pixels wide, drawn one pixel per pixel
/// into a 608×368 image and shown scaled up without smoothing, as the characters are.
struct OfficeGeometry {
    static let width = 608
    static let height = 368
    static let wallHeight = 46
    static let skirting = 9
    /// Where tile (0, 0)'s top corner falls, on the floor.
    static let origin = CGPoint(x: 216, y: 58)

    static func point(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        CGPoint(x: origin.x + (x - y) * 16, y: origin.y + (x + y) * 8 - z)
    }

    /// The scale to show it at in a view this wide: whole or half steps, so every pixel is as big as
    /// the next.
    static func scale(forWidth width: CGFloat) -> CGFloat {
        max(1, (width / CGFloat(Self.width) * 2).rounded(.down) / 2)
    }

    let scale: CGFloat
    /// Where the picture's top-left sits in the view.
    let offset: CGPoint

    init(size: CGSize) {
        let scale = min(Self.scale(forWidth: size.width), max(0.5, (size.height / CGFloat(Self.height) * 2).rounded(.down) / 2))
        self.scale = scale
        offset = CGPoint(x: ((size.width - CGFloat(Self.width) * scale) / 2).rounded(), y: ((size.height - CGFloat(Self.height) * scale) / 2).rounded())
    }

    /// A point in the view, in the picture's pixels.
    func pixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    /// A rack unit's plate, in the picture's pixels.
    static func unitRect(_ index: Int) -> CGRect? {
        let rack = index / OfficeFloor.unitsPerRack
        guard rack < OfficeFloor.racks else { return nil }
        let unit = index % OfficeFloor.unitsPerRack
        let tile = OfficeFloor.rackTile(rack)
        let corner = point(Double(tile.x) + 0.25, Double(tile.y) + 0.75, Double(33 - unit * 8))
        return CGRect(x: corner.x, y: corner.y, width: 8, height: 10)
    }
}

/// Draws one frame of the office: the background, then furniture, walls and people back to front,
/// then signs, name tags and balloons on top, all from `OfficeArt`'s sprites.
@MainActor
struct OfficeRenderer {
    let night: Bool
    let cast: OfficeCast
    let figures: [OfficeStage.Figure]
    let machines: [OfficeMachine]
    var hoveredMachine: String?
    let date: Date

    private var art: OfficeArt { .shared }
    private var palette: OfficePalette { OfficePalette(night: night) }

    private struct Item {
        var depth: Double
        var order: Int
        var draw: (CGContext) -> Void
    }

    // MARK: The frame

    func frame() -> CGImage? {
        let width = OfficeGeometry.width, height = OfficeGeometry.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        if let background = art.background(backgroundKey) { draw(background, at: 0, 0, in: context) }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        place(art.clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0), at: OfficeGeometry.point(0, 2, 33), in: context)

        var items: [Item] = []
        furnitureItems(&items)
        wallItems(&items)
        peopleItems(&items)
        items.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.order < $1.order }
        for item in items { item.draw(context) }
        labels(in: context)
        return context.makeImage()
    }

    var backgroundKey: OfficeArt.BackgroundKey {
        OfficeArt.BackgroundKey(night: night, zones: cast.zones, zoneTitles: cast.zones.map { cast.title(of: $0) }, rooms: cast.rooms,
                                leadZone: cast.leadTeam.flatMap(cast.zone(of:)), roomZones: cast.rooms.map { $0.flatMap(cast.zone(of:)) })
    }

    /// An image with its top-left at (x, y), in the picture's top-down pixels.
    private func draw(_ image: CGImage, at x: Int, _ y: Int, in context: CGContext, alpha: Double = 1) {
        context.setAlpha(alpha)
        context.draw(image, in: CGRect(x: x, y: OfficeGeometry.height - y - image.height, width: image.width, height: image.height))
        context.setAlpha(1)
    }

    private func place(_ sprite: OfficeSprite?, at point: CGPoint, in context: CGContext, alpha: Double = 1) {
        guard let sprite else { return }
        draw(sprite.image, at: Int(point.x.rounded(.down)) + sprite.dx, Int(point.y.rounded(.down)) + sprite.dy, in: context, alpha: alpha)
    }

    // MARK: Furniture and walls

    private func furnitureItems(_ items: inout [Item]) {
        for (tile, piece) in OfficeFloor.standard.furniture {
            let x = Double(tile.x), y = Double(tile.y)
            let corner = OfficeGeometry.point(x, y)
            switch piece {
            case .chair:
                let sprite = art.furniture(.chair, night: night)
                items.append(Item(depth: x + y + 0.8, order: 1) { place(sprite, at: corner, in: $0) })
            case .rack(let rack):
                let sprite = art.furniture(piece, night: night)
                items.append(Item(depth: x + y + 1, order: 2) { context in
                    place(sprite, at: corner, in: context)
                    units(of: rack, in: context)
                })
            case .desk:
                let sprite = art.furniture(.desk, night: night, lit: night && isLit(tile))
                items.append(Item(depth: x + y + 1, order: 3) { place(sprite, at: corner, in: $0) })
            default:
                let sprite = art.furniture(piece, night: night)
                items.append(Item(depth: x + y + 1, order: 2) { place(sprite, at: corner, in: $0) })
            }
        }
    }

    /// Whether someone's working at a desk, so at night its screen glows.
    private func isLit(_ desk: Tile) -> Bool {
        figures.contains { $0.seated && Int($0.x) == desk.x && Int($0.y) + 1 == desk.y && cast.members[$0.id]?.shown.isAtWork == true }
    }

    private func units(of rack: Int, in context: CGContext) {
        let frame = Int(date.timeIntervalSinceReferenceDate * 5)
        for unit in 0..<OfficeFloor.unitsPerRack {
            let index = rack * OfficeFloor.unitsPerRack + unit
            guard let rect = OfficeGeometry.unitRect(index) else { continue }
            let machine = index < machines.count ? machines[index] : nil
            let sprite = art.unit(machine?.state, frame: frame + index, hovered: machine != nil && machine?.id == hoveredMachine)
            place(sprite, at: rect.origin, in: context)
        }
    }

    private func wallItems(_ items: inout [Item]) {
        let ownerIn = figures.contains { $0.id == "owner" }
        for room in 1..<OfficeFloor.rooms {
            let x = room * OfficeFloor.roomWidth - 1
            for y in 0..<OfficeFloor.roomDepth {
                let sprite = art.partition(night: night, front: y == OfficeFloor.roomDepth - 1)
                let corner = OfficeGeometry.point(Double(x), Double(y))
                items.append(Item(depth: Double(x + y) + 1.5, order: 5) { place(sprite, at: corner, in: $0) })
            }
        }
        // The offices' glass fronts, each with its door.
        let height = Double(OfficeGeometry.wallHeight)
        for x in 0..<OfficeFloor.width {
            let room = x / OfficeFloor.roomWidth
            let corner = OfficeGeometry.point(Double(x), 3)
            let sprite = OfficeFloor.door(room: room).x == x
                ? art.door(open: room != 0 || ownerIn, height: height, night: night, inward: true)
                : art.glass(along: .x, height: height, night: night)
            items.append(Item(depth: Double(x + 3) + 1.5, order: 6) { place(sprite, at: corner, in: $0) })
        }
        // The server room: glass toward the open space, and its door from the corridor.
        for y in OfficeFloor.openStart..<OfficeFloor.depth {
            let corner = OfficeGeometry.point(Double(OfficeFloor.serverStart - 1), Double(y))
            let sprite = art.glass(along: .y, height: 34, night: night)
            items.append(Item(depth: Double(OfficeFloor.serverStart - 1 + y) + 1.5, order: 6) { place(sprite, at: corner, in: $0) })
        }
        for x in OfficeFloor.serverStart..<OfficeFloor.width {
            let y = OfficeFloor.openStart - 1
            let corner = OfficeGeometry.point(Double(x), Double(y))
            let sprite = x == OfficeFloor.serverDoor.x ? art.door(open: true, height: 34, night: night, inward: false)
                : art.glass(along: .x, height: 34, night: night)
            items.append(Item(depth: Double(x + y) + 1.5, order: 6) { place(sprite, at: corner, in: $0) })
        }
    }

    // MARK: People

    /// Where someone stands: the middle of their tile; or, in a chair, at its edge toward the desk.
    static func anchor(_ figure: OfficeStage.Figure) -> (Double, Double) {
        figure.seated ? (figure.x + 0.5, figure.y + 0.98) : (figure.x + 0.5, figure.y + 0.5)
    }

    /// The rectangle someone's sprite fills, in the picture's pixels: feet on their anchor, a little
    /// higher in a chair.
    static func spriteRect(_ figure: OfficeStage.Figure) -> CGRect {
        let (ax, ay) = anchor(figure)
        let foot = OfficeGeometry.point(ax, ay)
        let lift: CGFloat = figure.seated ? 3 : 0
        return CGRect(x: foot.x.rounded(.down) - 7, y: foot.y.rounded(.down) - 17 - lift,
                      width: CGFloat(OfficeSprites.width), height: CGFloat(OfficeSprites.height))
    }

    private func peopleItems(_ items: inout [Item]) {
        for figure in figures {
            guard let member = cast.members[figure.id] else { continue }
            let (ax, ay) = Self.anchor(figure)
            items.append(Item(depth: ax + ay, order: 4) { context in person(figure, member, in: context) })
        }
    }

    private func pose(_ figure: OfficeStage.Figure, _ member: OfficeCast.Member) -> (OfficeSprites.Pose, Bool) {
        let phase = Double(OfficeNames.hash(figure.id) % 97) / 97
        let t = date.timeIntervalSinceReferenceDate + phase * 3
        if figure.moving {
            let step = Int(t / (OfficeStage.step / 2)) % 2 == 0
            return figure.heading.isBack ? (step ? .back1 : .back2, figure.heading.isMirrored) : (step ? .walk1 : .walk2, figure.heading.isMirrored)
        }
        guard figure.seated else { return (figure.heading.isBack ? .backStand : .stand, figure.heading.isMirrored) }
        switch member.shown {
        case .working: return (Int(t * 4) % 2 == 0 ? .type1 : .type2, false)
        case .talking: return (Int(t * 1.6) % 2 == 0 ? .talk : .sit, false)
        case .done: return (Int(t * 3) % 2 == 0 ? .cheer1 : .cheer2, false)
        case .idle, .away: return (.sit, false)
        }
    }

    private func person(_ figure: OfficeStage.Figure, _ member: OfficeCast.Member, in context: CGContext) {
        let rect = Self.spriteRect(figure)
        if !figure.seated {
            let (ax, ay) = Self.anchor(figure)
            place(art.shadow(), at: OfficeGeometry.point(ax, ay), in: context, alpha: figure.opacity)
        }
        let (pose, mirrored) = pose(figure, member)
        // At night only a lit screen shows someone's true colours.
        let tint = figure.seated && member.shown.isAtWork ? nil : palette.spriteTint
        let look = OfficeLook.look(for: member.id, role: member.person.role)
        if let image = art.person(look, pose, mirrored: mirrored, tint: tint) {
            draw(image, at: Int(rect.minX), Int(rect.minY), in: context, alpha: figure.opacity)
        }
    }

    // MARK: Labels

    private func labels(in context: CGContext) {
        for room in 0..<OfficeFloor.rooms { sign(room, in: context) }
        if !figures.contains(where: { $0.id == "owner" }) {
            place(art.backLater(), at: OfficeGeometry.point(Double(OfficeFloor.door(room: 0).x) + 0.5, 4, 20), in: context)
        }
        let ordered = figures.sorted { Self.anchor($0).0 + Self.anchor($0).1 < Self.anchor($1).0 + Self.anchor($1).1 }
        for figure in ordered {
            guard let member = cast.members[figure.id] else { continue }
            let (ax, ay) = Self.anchor(figure)
            let at = figure.seated ? OfficeGeometry.point(ax, ay + 0.9) : OfficeGeometry.point(ax, ay, -2)
            place(art.nameTag(member.name, dot: member.person.board.map { Pixel.rgb($0.swatch.hex) }), at: at, in: context, alpha: figure.opacity)
        }
        for zone in 0..<OfficeFloor.zones {
            let extra = cast.overflow(zone: zone)
            guard extra > 0 else { continue }
            place(art.badge("+\(extra)", fill: Pixel.rgb(OfficePalette.zoneSwatches[zone].hex)),
                  at: OfficeGeometry.point(Double(zone * OfficeFloor.zoneWidth) + 3.5, 12.4), in: context)
        }
        // Balloons last: they're what you read.
        for figure in ordered where figure.seated {
            guard let member = cast.members[figure.id], member.shown == .talking, let label = member.label else { continue }
            let (ax, ay) = Self.anchor(figure)
            let board = member.person.board
            let edge = board.map { $0.needsYou || $0 == .blocked } == true ? Pixel.rgb(board!.swatch.hex) : Pixel.outline
            place(art.balloon(label, edge: edge), at: OfficeGeometry.point(ax, ay, 22), in: context, alpha: figure.opacity)
        }
    }

    /// The sign over an office's door: "Owner", "Lead", or the team's name.
    private func sign(_ room: Int, in context: CGContext) {
        let title: String
        var subtitle: String?
        var zone: Int?
        switch room {
        case 0:
            title = String(localized: "Owner")
            subtitle = cast.owner?.name
        case 1:
            title = String(localized: "Lead")
            subtitle = cast.title(of: cast.leadTeam)
            zone = cast.leadTeam.flatMap(cast.zone(of:))
        default:
            let team = cast.rooms[room - 2]
            title = cast.title(of: team) ?? String(localized: "Vacant")
            zone = team.flatMap(cast.zone(of:))
        }
        let bar = zone.map { Pixel.rgb(OfficePalette.zoneSwatches[$0].hex) } ?? Pixel.rgb(room == 0 ? Swatch.amber.hex : 0x8C95A8)
        let door = OfficeFloor.door(room: room)
        place(art.sign(PixelFont.fittingWords(title, width: 52), subtitle: subtitle, bar: bar),
              at: OfficeGeometry.point(Double(door.x) + 0.5, 4, 41), in: context)
    }
}
