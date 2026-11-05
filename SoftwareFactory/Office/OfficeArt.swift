import CoreGraphics
import Foundation

/// A piece of pixel art and where it sits: its top-left is `dx`, `dy` from the point it's drawn at
/// (a tile's top corner, or a label's centre).
struct OfficeSprite {
    let image: CGImage
    let dx: Int
    let dy: Int
    var width: Int { image.width }
    var height: Int { image.height }
}

/// Paints in isometric pixels: a tile's (x, y) and a height z, two pixels across and one down per
/// eighth of a tile along x, so every edge is a clean 2:1 step.
nonisolated struct IsoPainter {
    var canvas: PixelCanvas
    /// Where (0, 0, 0) falls in the canvas.
    let originX: Double
    let originY: Double

    func p(_ x: Double, _ y: Double, _ z: Double = 0) -> CGPoint {
        CGPoint(x: originX + (x - y) * 16, y: originY + (x + y) * 8 - z)
    }

    func pixel(_ x: Double, _ y: Double, _ z: Double = 0) -> (Int, Int) {
        let point = p(x, y, z)
        return (Int(point.x.rounded(.down)), Int(point.y.rounded(.down)))
    }

    mutating func quad(_ points: [(Double, Double, Double)], _ color: UInt32) {
        canvas.fill(points.map { p($0.0, $0.1, $0.2) }, color)
    }

    /// A box: its top, its face toward you on the left (+y) and on the right (+x), with a light edge
    /// along the top's front.
    mutating func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ z0: Double, _ z1: Double,
                      top: UInt32, left: UInt32, right: UInt32, edge: Bool = true) {
        quad([(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], left)
        quad([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], right)
        quad([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], top)
        if edge {
            let light = Pixel.light(top, 0.35)
            canvas.line(pixel(x0, y1, z1), pixel(x1, y1, z1), light)
            canvas.line(pixel(x1, y0, z1), pixel(x1, y1, z1), light)
        }
    }

    mutating func line(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ color: UInt32) {
        canvas.line(pixel(a.0, a.1, a.2), pixel(b.0, b.1, b.2), color)
    }
}

/// The office's colours by day and by night, as pixels.
nonisolated struct OfficePalette {
    let night: Bool

    static let zoneSwatches: [Swatch] = [.lime, .tide, .cobalt, .orchid, .rose]

    private func tone(_ day: UInt32, _ night: UInt32) -> UInt32 { Pixel.rgb(self.night ? night : day) }

    var outside: UInt32 { tone(0x16161C, 0x0B0B12) }
    var corridor: (UInt32, UInt32) { (tone(0xE9DFCB, 0x3A3A4A), tone(0xDFD3BC, 0x35354A)) }
    var carpet: (UInt32, UInt32) { (tone(0xC99B6D, 0x4A3A3E), tone(0xC09265, 0x45373C)) }
    var server: (UInt32, UInt32) { (tone(0xA9B0BE, 0x2B2F3E), tone(0xA1A8B6, 0x282C3A)) }
    var vacant: (UInt32, UInt32) { (tone(0xD6D2C8, 0x33333F), tone(0xCCC8BE, 0x2F2F3B)) }
    var wallLeft: UInt32 { tone(0xF1E6D2, 0x2E3048) }
    var wallRight: UInt32 { tone(0xE6D8BF, 0x282A40) }
    var wallCap: UInt32 { tone(0x8A6A52, 0x1C1D2C) }
    var sky: UInt32 { tone(0x8FD3FF, 0x101735) }
    var skyLow: UInt32 { tone(0xC6E9FF, 0x1C2550) }
    var frame: UInt32 { tone(0xFFFFFF, 0x5A5E80) }
    var skirting: UInt32 { tone(0x6B4A3A, 0x231E2A) }
    var skirtingSide: UInt32 { tone(0x543A2E, 0x1A1620) }
    var deskTop: UInt32 { tone(0xF2D3A4, 0x8C7A66) }
    var deskLeft: UInt32 { tone(0xC9995C, 0x5E4E40) }
    var deskRight: UInt32 { tone(0xA87A45, 0x4A3D33) }
    var chair: UInt32 { tone(0x4A5AB0, 0x2C3366) }
    var chairShade: UInt32 { tone(0x34408A, 0x20264D) }
    var monitor: UInt32 { tone(0x3A3F4F, 0x2A2E3C) }
    var glass: UInt32 { night ? 0x406C8CFF : 0x58BFE6FF }
    var glassFrame: UInt32 { tone(0xFFFFFF, 0x7C84B0) }
    var door: UInt32 { tone(0xB07A4C, 0x5A4234) }
    var doorShade: UInt32 { tone(0x8E5E36, 0x463428) }
    var leaf: UInt32 { tone(0x4FA35A, 0x2F6A44) }
    var leafLight: UInt32 { tone(0x7CC66A, 0x3E8A55) }
    var pot: UInt32 { tone(0xC0602C, 0x7A4A30) }
    var potShade: UInt32 { tone(0x96461E, 0x5E3824) }
    var rackTop: UInt32 { tone(0x4A5064, 0x3A3F52) }
    var rackLeft: UInt32 { tone(0x2A2E3A, 0x1E2130) }
    var rackRight: UInt32 { tone(0x1E212B, 0x161925) }
    var cabinet: UInt32 { tone(0xD8DCE6, 0x55596E) }
    var cabinetShade: UInt32 { tone(0xB4B9C6, 0x44475A) }
    var sofa: UInt32 { tone(0xE0557F, 0x7A3550) }
    var sofaShade: UInt32 { tone(0xB8406A, 0x5E2840) }
    var paper: UInt32 { Pixel.rgb(0xFFFDF6) }
    var ink: UInt32 { Pixel.rgb(0x0B0B0D) }
    var text: UInt32 { Pixel.rgb(0xF5F2EC) }
    /// People under night lights.
    var spriteTint: UInt32? { night ? Pixel.rgb(0xB9C2F0) : nil }

    func zone(_ index: Int) -> (UInt32, UInt32) {
        let color = Pixel.rgb(Self.zoneSwatches[index % Self.zoneSwatches.count].hex)
        if night { return (Pixel.mix(color, Pixel.rgb(0x1A1D33), 0.72), Pixel.mix(color, Pixel.rgb(0x1A1D33), 0.68)) }
        return (Pixel.mix(color, 0xFFFFFFFF, 0.58), Pixel.mix(color, 0xFFFFFFFF, 0.5))
    }

    func roomCarpet(_ zone: Int?) -> (UInt32, UInt32) {
        guard let zone else { return carpet }
        let (a, b) = self.zone(zone)
        return (Pixel.mix(a, carpet.0, 0.45), Pixel.mix(b, carpet.1, 0.45))
    }

    var ownerCarpet: (UInt32, UInt32) {
        (Pixel.mix(carpet.0, Pixel.rgb(0xD9534F), 0.25), Pixel.mix(carpet.1, Pixel.rgb(0xD9534F), 0.25))
    }
}

/// The office's pixel art, made once and kept: the floor and walls, each piece of furniture, glass,
/// doors, signs, name tags, balloons, rack units and the people. Day and night are kept apart.
@MainActor
final class OfficeArt {
    static let shared = OfficeArt()

    private var sprites: [String: OfficeSprite] = [:]
    private var backgrounds: [String: CGImage] = [:]
    private var people: [String: CGImage] = [:]

    /// Made once per key; `paint` draws it.
    private func sprite(_ key: String, _ make: () -> OfficeSprite?) -> OfficeSprite? {
        if let sprite = sprites[key] { return sprite }
        guard let sprite = make() else { return nil }
        if sprites.count > 2000 { sprites.removeAll() }
        sprites[key] = sprite
        return sprite
    }

    /// A one-tile sprite: `height` pixels above the floor, outlined like the characters when `outline`.
    private func tileSprite(height: Int, outline: Bool = true, _ paint: (inout IsoPainter) -> Void) -> OfficeSprite? {
        let top = height + 3
        var painter = IsoPainter(canvas: PixelCanvas(width: 38, height: top + 28), originX: 19, originY: Double(top))
        paint(&painter)
        if outline { painter.canvas.outline(Pixel.outline) }
        return painter.canvas.image.map { OfficeSprite(image: $0, dx: -19, dy: -top) }
    }

    // MARK: Floor and walls

    struct BackgroundKey: Hashable {
        var night: Bool
        var zones: [String?]
        var zoneTitles: [String?]
        var rooms: [String?]
        var leadZone: Int?
        var roomZones: [Int?]
    }

    /// The floor, its skirting with the zones' names, and the back walls with their windows and the
    /// way in: everything that never moves.
    func background(_ key: BackgroundKey) -> CGImage? {
        let id = "\(key)"
        if let image = backgrounds[id] { return image }
        let palette = OfficePalette(night: key.night)
        let w = Double(OfficeFloor.width), d = Double(OfficeFloor.depth), k = Double(OfficeGeometry.skirting)
        let origin = OfficeGeometry.origin

        // The floor, with its skirting, outlined as one block.
        var floor = IsoPainter(canvas: PixelCanvas(width: OfficeGeometry.width, height: OfficeGeometry.height), originX: origin.x, originY: origin.y)
        for y in 0..<OfficeFloor.depth {
            for x in 0..<OfficeFloor.width {
                let tile = Tile(x, y)
                let (a, b) = floorColors(tile, key: key, palette: palette)
                let color = (x + y) % 2 == 0 ? a : b
                let (fx, fy) = (Double(x), Double(y))
                floor.quad([(fx, fy, 0), (fx + 1, fy, 0), (fx + 1, fy + 1, 0), (fx, fy + 1, 0)], color)
                switch OfficeFloor.region(of: tile) {
                case .servers?:
                    // Raised floor panels.
                    let seam = Pixel.shade(color, 0.14)
                    floor.line((fx, fy + 1, 0), (fx + 1, fy + 1, 0), seam)
                    floor.line((fx + 1, fy, 0), (fx + 1, fy + 1, 0), seam)
                case .corridor?:
                    floor.line((fx, fy + 1, 0), (fx + 1, fy + 1, 0), Pixel.shade(color, 0.06))
                default:
                    break
                }
            }
        }
        // A doormat by the way in.
        floor.quad([(0, 4.25, 0), (0.875, 4.25, 0), (0.875, 5.75, 0), (0, 5.75, 0)], Pixel.mix(palette.wallCap, palette.corridor.1, 0.35))
        floor.quad([(0, d, 0), (w, d, 0), (w, d, -k), (0, d, -k)], palette.skirting)
        floor.quad([(w, 0, 0), (w, d, 0), (w, d, -k), (w, 0, -k)], palette.skirtingSide)
        floor.line((0, d, 0), (w, d, 0), Pixel.light(palette.skirting, 0.3))
        floor.line((w, 0, 0), (w, d, 0), Pixel.light(palette.skirtingSide, 0.3))
        floor.canvas.outline(Pixel.outline)

        // The zones' names, painted on the skirting.
        for zone in 0..<OfficeFloor.zones {
            let title = key.zoneTitles[zone] ?? String(localized: "Vacant")
            let color = key.zones[zone] == nil ? Pixel.rgb(0x8A7A70) : Pixel.light(Pixel.rgb(OfficePalette.zoneSwatches[zone].hex), 0.2)
            paintSkirtingLabel(PixelFont.fittingWords(title, width: 4 * 16 - 4), color: color, centre: floor.p(Double(zone * 4) + 2, d, -k / 2 + 0.5), into: &floor.canvas)
        }
        paintSkirtingLabel(String(localized: "Servers"), color: Pixel.rgb(0xCFC6BE), centre: floor.p(22, d, -k / 2 + 0.5), into: &floor.canvas)

        // The back walls: left (x = 0) and right (y = 0), with a cap along their tops.
        let h = Double(OfficeGeometry.wallHeight)
        var walls = IsoPainter(canvas: PixelCanvas(width: OfficeGeometry.width, height: OfficeGeometry.height), originX: origin.x, originY: origin.y)
        walls.quad([(0, d, 0), (0, 0, 0), (0, 0, h), (0, d, h)], palette.wallLeft)
        walls.quad([(0, 0, 0), (w, 0, 0), (w, 0, h), (0, 0, h)], palette.wallRight)
        walls.quad([(0, d, 0), (0, 0, 0), (0, 0, 13), (0, d, 13)], Pixel.shade(palette.wallLeft, 0.06))
        walls.quad([(0, 0, 0), (w, 0, 0), (w, 0, 13), (0, 0, 13)], Pixel.shade(palette.wallRight, 0.06))
        walls.line((0, d, 13), (0, 0, 13), Pixel.shade(palette.wallLeft, 0.2))
        walls.line((0, 0, 13), (w, 0, 13), Pixel.shade(palette.wallRight, 0.2))
        walls.quad([(0, d, h), (0, 0, h), (-0.25, -0.25, h), (-0.25, d, h)], palette.wallCap)
        walls.quad([(-0.25, -0.25, h), (w, -0.25, h), (w, 0, h), (0, 0, h)], palette.wallCap)
        for room in 0..<OfficeFloor.rooms {
            let x0 = Double(room * OfficeFloor.roomWidth)
            window(&walls, palette: palette, along: .x, from: x0 + 0.75, to: x0 + 3.25, seed: room)
        }
        window(&walls, palette: palette, along: .y, from: 6.5, to: 9.25, seed: 7)
        window(&walls, palette: palette, along: .y, from: 9.75, to: 12.5, seed: 8)
        // The way in: a doorway with a sign over it.
        walls.quad([(0, 4.125, 0), (0, 5.875, 0), (0, 5.875, 32), (0, 4.125, 32)], palette.wallCap)
        walls.quad([(0, 4.375, 0), (0, 5.625, 0), (0, 5.625, 30), (0, 4.375, 30)], key.night ? Pixel.rgb(0x07070C) : Pixel.rgb(0x3A2E2A))
        walls.canvas.outline(Pixel.outline)
        let sign = plate(String(localized: "In · Out"), fill: Pixel.shade(Pixel.rgb(Swatch.mint.hex), 0.35), text: palette.paper, bar: nil)
        let signCentre = walls.p(0, 5, 39)
        walls.canvas.draw(sign, x: Int(signCentre.x) - sign.width / 2, y: Int(signCentre.y) - sign.height / 2)

        var canvas = PixelCanvas(width: OfficeGeometry.width, height: OfficeGeometry.height)
        canvas.draw(floor.canvas, x: 0, y: 0)
        canvas.draw(walls.canvas, x: 0, y: 0)
        let image = canvas.image
        if backgrounds.count > 8 { backgrounds.removeAll() }
        backgrounds[id] = image
        return image
    }

    private func floorColors(_ tile: Tile, key: BackgroundKey, palette: OfficePalette) -> (UInt32, UInt32) {
        switch OfficeFloor.region(of: tile) {
        case .room(let room)?:
            switch room {
            case 0: return palette.ownerCarpet
            case 1: return palette.roomCarpet(key.leadZone)
            default: return palette.roomCarpet(key.roomZones[room - 2])
            }
        case .corridor?: return palette.corridor
        case .zone(let zone)?: return key.zones[zone] == nil ? palette.vacant : palette.zone(zone)
        case .servers?: return palette.server
        case nil: return palette.vacant
        }
    }

    /// Lettering along the skirting: each letter whole, stepping down with the edge.
    private func paintSkirtingLabel(_ text: String, color: UInt32, centre: CGPoint, into canvas: inout PixelCanvas) {
        let width = PixelFont.width(text)
        let x = Int(centre.x) - width / 2
        let y = Int(centre.y) - width / 4 - PixelFont.height / 2
        PixelFont.draw(text, in: &canvas, x: x, y: y, color: color, slope: 1)
    }

    enum Along { case x, y }

    /// A window on a back wall, with sky, a cloud (or stars) and a frame.
    private func window(_ walls: inout IsoPainter, palette: OfficePalette, along: Along, from a: Double, to b: Double, seed: Int) {
        func q(_ s: Double, _ z: Double) -> (Double, Double, Double) { along == .x ? (s, 0, z) : (0, s, z) }
        walls.quad([q(a, 17), q(b, 17), q(b, 38), q(a, 38)], palette.frame)
        walls.quad([q(a + 0.125, 19), q(b - 0.125, 19), q(b - 0.125, 36), q(a + 0.125, 36)], palette.skyLow)
        walls.quad([q(a + 0.125, 27), q(b - 0.125, 27), q(b - 0.125, 36), q(a + 0.125, 36)], palette.sky)
        let middle = (a + b) / 2
        walls.line(q(middle, 19), q(middle, 36), palette.frame)
        let spot = walls.pixel(q(a + 0.5 + Double(seed % 3) * 0.25, 33).0, q(a + 0.5 + Double(seed % 3) * 0.25, 33).1, 33)
        if palette.night {
            for (dx, dy) in [(0, 0), (9, 3), (17, -2), (26, 4), (5, 7)] { walls.canvas.plot(spot.0 + dx, spot.1 + dy, 0xFFFFFFFF) }
        } else {
            for (dx, dy, w) in [(1, 0, 4), (0, 1, 7), (2, -1, 2)] { walls.canvas.fill(x: spot.0 + dx, y: spot.1 + dy, width: w, height: 1, 0xFFFFFFFF) }
        }
    }

    // MARK: Furniture

    func furniture(_ piece: OfficeFloor.Furniture, night: Bool, lit: Bool = false) -> OfficeSprite? {
        let palette = OfficePalette(night: night)
        switch piece {
        case .desk:
            return sprite("desk-\(night)-\(lit)") {
                tileSprite(height: 20) { p in
                    p.box(0.125, 0.125, 0.875, 0.75, 0, 9, top: palette.deskTop, left: palette.deskLeft, right: palette.deskRight)
                    // A keyboard, a mug, and the monitor with its back to you.
                    p.quad([(0.5, 0.375, 9), (0.75, 0.375, 9), (0.75, 0.5, 9), (0.5, 0.5, 9)], Pixel.shade(palette.deskTop, 0.3))
                    p.box(0.25, 0.25, 0.375, 0.375, 9, 11, top: palette.monitor, left: palette.monitor, right: palette.monitor, edge: false)
                    p.box(0.125, 0.125, 0.5, 0.25, 11, 20, top: Pixel.light(palette.monitor, 0.15), left: palette.monitor,
                          right: Pixel.shade(palette.monitor, 0.3), edge: false)
                    if lit { p.line((0.125, 0.125, 20), (0.5, 0.125, 20), Pixel.rgb(0x8FE3FF)) }
                    let mug = p.pixel(0.75, 0.625, 12)
                    p.canvas.fill(x: mug.0, y: mug.1, width: 2, height: 3, palette.paper)
                    p.canvas.plot(mug.0 + 2, mug.1 + 1, palette.paper)
                }
            }
        case .chair:
            return sprite("chair-\(night)") {
                tileSprite(height: 16) { p in
                    p.line((0.5, 0.75, 0), (0.5, 0.75, 4), palette.monitor)
                    p.line((0.375, 0.75, 0), (0.625, 0.75, 0), palette.monitor)
                    p.box(0.25, 0.625, 0.75, 1.0, 4, 6, top: palette.chair, left: palette.chairShade, right: palette.chairShade)
                    p.box(0.25, 0.5, 0.75, 0.625, 6, 15, top: palette.chair, left: palette.chair, right: palette.chairShade)
                }
            }
        case .plant:
            return sprite("plant-\(night)") {
                tileSprite(height: 24) { p in
                    p.box(0.25, 0.25, 0.75, 0.75, 0, 7, top: palette.potShade, left: palette.pot, right: palette.potShade)
                    let centre = p.pixel(0.5, 0.5, 15)
                    for (dx, dy, w, h, light) in [(-8, -2, 9, 8, false), (0, -2, 9, 8, false), (-5, -8, 10, 9, false), (-4, -6, 4, 3, true), (1, -7, 3, 2, true), (2, 0, 3, 2, true)] {
                        p.canvas.ellipse(x: centre.0 + dx, y: centre.1 + dy, width: w, height: h, light ? palette.leafLight : palette.leaf)
                    }
                }
            }
        case .cabinet:
            return sprite("cabinet-\(night)") {
                tileSprite(height: 22) { p in
                    p.box(0.125, 0.125, 0.875, 0.625, 0, 21, top: Pixel.light(palette.cabinet, 0.1), left: palette.cabinet, right: palette.cabinetShade)
                    for z in [7.0, 14.0] { p.line((0.25, 0.625, z), (0.75, 0.625, z), palette.cabinetShade) }
                    for z in [4.0, 11.0, 18.0] {
                        let handle = p.pixel(0.5, 0.625, z)
                        p.canvas.fill(x: handle.0 - 1, y: handle.1, width: 3, height: 1, Pixel.shade(palette.cabinetShade, 0.3))
                    }
                }
            }
        case .sofa:
            return sprite("sofa-\(night)") {
                tileSprite(height: 15) { p in
                    p.box(0.125, 0.125, 0.875, 0.75, 0, 7, top: palette.sofa, left: palette.sofaShade, right: palette.sofaShade)
                    p.box(0.125, 0.125, 0.875, 0.3125, 7, 14, top: Pixel.light(palette.sofa, 0.15), left: palette.sofa, right: palette.sofaShade)
                }
            }
        case .cooler:
            return sprite("cooler-\(night)") {
                tileSprite(height: 25) { p in
                    p.box(0.25, 0.25, 0.75, 0.75, 0, 14, top: palette.cabinet, left: palette.cabinet, right: palette.cabinetShade)
                    p.box(0.375, 0.375, 0.625, 0.625, 14, 24, top: Pixel.rgb(0xBFE8FF), left: Pixel.rgb(0x7FC4F0), right: Pixel.rgb(0x5FA4D8))
                }
            }
        case .rack:
            return sprite("rack-\(night)") {
                tileSprite(height: 37) { p in
                    p.box(0.125, 0.25, 0.875, 0.75, 0, 36, top: palette.rackTop, left: palette.rackLeft, right: palette.rackRight)
                    for step in 0..<3 { p.line((0.25 + Double(step) * 0.1875, 0.375, 36), (0.25 + Double(step) * 0.1875, 0.625, 36), palette.rackRight) }
                }
            }
        }
    }

    /// A rack unit's plate: on, building (its lights blinking by `frame`), off, out of sight, or empty.
    func unit(_ state: OfficeMachine.State?, frame: Int, hovered: Bool) -> OfficeSprite? {
        sprite("unit-\(state.map(\.rawValue) ?? "empty")-\(state == .test ? frame % 4 : 0)-\(hovered)") {
            var plate = PixelCanvas(width: 8, height: 6)
            switch state {
            case nil:
                plate.fill(x: 0, y: 0, width: 8, height: 6, Pixel.rgb(0x22252F))
            case .on?:
                plate.fill(x: 0, y: 0, width: 8, height: 6, Pixel.rgb(0x15181F))
                for x in [1, 3, 5] { plate.fill(x: x, y: 2, width: 1, height: 2, Pixel.rgb(Swatch.mint.hex)) }
            case .test?:
                plate.fill(x: 0, y: 0, width: 8, height: 6, Pixel.rgb(0x5B3FB0))
                let pattern = [0b10110, 0b01101, 0b11010, 0b00111][frame % 4]
                for led in 0..<5 where (pattern >> led) & 1 == 1 {
                    plate.fill(x: 1 + led, y: 2, width: 1, height: 2, led % 2 == 0 ? Pixel.rgb(Swatch.mint.hex) : Pixel.rgb(0xEFE6FF))
                }
            case .off?:
                plate.fill(x: 0, y: 0, width: 8, height: 6, Pixel.rgb(0x5A5F6E))
                plate.fill(x: 1, y: 2, width: 1, height: 2, Pixel.rgb(0x30333C))
            case .unknown?:
                plate.fill(x: 0, y: 0, width: 8, height: 6, Pixel.rgb(0x3A3F4C))
                for y in 0..<6 { for x in 0..<8 where (x + y) % 3 == 0 { plate[x, y] = Pixel.rgb(0x7A8296) } }
                PixelFont.draw("?", in: &plate, x: 3, y: 0, color: 0xFFFFFFFF)
            }
            if hovered {
                for x in 0..<8 { plate[x, 0] = 0xFFFFFFFF; plate[x, 5] = 0xFFFFFFFF }
                for y in 0..<6 { plate[0, y] = 0xFFFFFFFF; plate[7, y] = 0xFFFFFFFF }
            }
            return plate.sheared(falling: true).image.map { OfficeSprite(image: $0, dx: 0, dy: 0) }
        }
    }

    // MARK: Walls, glass and doors

    /// A wall between two offices, one tile of it: along y, at an x boundary.
    func partition(night: Bool, front: Bool) -> OfficeSprite? {
        let palette = OfficePalette(night: night)
        let h = Double(OfficeGeometry.wallHeight)
        return sprite("partition-\(night)-\(front)") {
            tileSprite(height: Int(h) + 2, outline: false) { p in
                // Drawn from the tile on its left: its far side is this tile's right edge.
                p.box(0.875, 0, 1, 1, 0, h, top: palette.wallCap, left: Pixel.shade(palette.wallLeft, 0.16), right: Pixel.shade(palette.wallLeft, 0.07), edge: false)
                p.line((1, 0, 13), (1, 1, 13), Pixel.shade(palette.wallLeft, 0.2))
                p.line((0.875, 0, h), (0.875, 1, h), Pixel.outline)
                p.line((1, 0, h), (1, 1, h), Pixel.outline)
                if front {
                    p.line((1, 1, 0), (1, 1, h), Pixel.outline)
                    p.line((0.875, 1, h), (1, 1, h), Pixel.outline)
                }
            }
        }
    }

    /// One tile of glass wall, along x (an office's front) or y (the server room's side).
    func glass(along: Along, height: Double, night: Bool) -> OfficeSprite? {
        let palette = OfficePalette(night: night)
        return sprite("glass-\(along)-\(height)-\(night)") {
            tileSprite(height: Int(height) + 2, outline: false) { p in
                func q(_ s: Double, _ z: Double) -> (Double, Double, Double) { along == .x ? (s, 1, z) : (1, s, z) }
                p.quad([q(0, 2), q(1, 2), q(1, height - 2), q(0, height - 2)], palette.glass)
                p.line(q(0.25, height * 0.3), q(0.5, height * 0.75), night ? 0x30FFFFFF : 0x90FFFFFF)
                p.line(q(0.375, height * 0.3), q(0.5, height * 0.55), night ? 0x20FFFFFF : 0x60FFFFFF)
                p.quad([q(0, height - 2), q(1, height - 2), q(1, height), q(0, height)], palette.glassFrame)
                p.quad([q(0, 0), q(1, 0), q(1, 2), q(0, 2)], palette.glassFrame)
                p.line(q(0, 0), q(0, height), palette.glassFrame)
                p.line(q(0, height), q(1, height), Pixel.outline)
            }
        }
    }

    /// A doorway in a glass front along x: open (the door swung in) or shut.
    func door(open: Bool, height: Double, night: Bool, inward: Bool) -> OfficeSprite? {
        let palette = OfficePalette(night: night)
        // An office's door swings back into the office; the server room's, forward into it.
        let swing = inward ? 0.375 : 1.625
        return sprite("door-\(open)-\(height)-\(night)-\(inward)") {
            tileSprite(height: Int(height) + 2, outline: false) { p in
                let top = (height * 0.72).rounded()
                if open {
                    // The door, against the inside of the glass.
                    p.quad([(0.875, 1, 0), (0.875, swing, 0), (0.875, swing, top - 1), (0.875, 1, top - 1)], palette.door)
                    p.line((0.875, swing, 0), (0.875, swing, top - 1), Pixel.outline)
                    p.line((0.875, swing, top - 1), (0.875, 1, top - 1), Pixel.outline)
                } else {
                    p.quad([(0.125, 1, 0), (0.875, 1, 0), (0.875, 1, top), (0.125, 1, top)], palette.door)
                    p.quad([(0.25, 1, 4), (0.75, 1, 4), (0.75, 1, top - 5), (0.25, 1, top - 5)], palette.doorShade)
                    p.quad([(0.3125, 1, 6), (0.6875, 1, 6), (0.6875, 1, top - 7), (0.3125, 1, top - 7)], palette.door)
                    let knob = p.pixel(0.75, 1, 15)
                    p.canvas.fill(x: knob.0, y: knob.1, width: 2, height: 2, Pixel.rgb(Swatch.amber.hex))
                }
                // The frame, and glass above it.
                p.quad([(0, 1, 0), (0.125, 1, 0), (0.125, 1, top), (0, 1, top)], palette.doorShade)
                p.quad([(0.875, 1, 0), (1, 1, 0), (1, 1, top), (0.875, 1, top)], palette.doorShade)
                p.quad([(0, 1, top), (1, 1, top), (1, 1, top + 2), (0, 1, top + 2)], palette.doorShade)
                p.quad([(0, 1, top + 2), (1, 1, top + 2), (1, 1, height - 2), (0, 1, height - 2)], palette.glass)
                p.quad([(0, 1, height - 2), (1, 1, height - 2), (1, 1, height), (0, 1, height)], palette.glassFrame)
                p.line((0, 1, height), (1, 1, height), Pixel.outline)
                p.line((0, 1, 0), (0, 1, top), Pixel.outline)
                p.line((1, 1, 0), (1, 1, top), Pixel.outline)
                if !open { p.line((0.125, 1, top), (0.875, 1, top), Pixel.outline) }
            }
        }
    }

    // MARK: Labels

    /// A plate with a word or two: paper, an outline and a coloured bar.
    private func plate(_ title: String, subtitle: String? = nil, fill: UInt32, text: UInt32, bar: UInt32?) -> PixelCanvas {
        let titleWidth = PixelFont.width(title)
        let subtitleText = subtitle.map { PixelFont.fittingWords($0, width: 50) }
        let width = max(titleWidth, subtitleText.map { PixelFont.width($0) } ?? 0) + (bar != nil ? 8 : 6)
        let height = subtitle != nil ? 15 : 9
        var canvas = PixelCanvas(width: width, height: height)
        canvas.fill(x: 1, y: 1, width: width - 2, height: height - 2, fill)
        for x in 1..<(width - 1) { canvas[x, 0] = Pixel.outline; canvas[x, height - 1] = Pixel.outline }
        for y in 1..<(height - 1) { canvas[0, y] = Pixel.outline; canvas[width - 1, y] = Pixel.outline }
        var left = 3
        if let bar {
            canvas.fill(x: 1, y: 1, width: 2, height: height - 2, bar)
            left = 5
        }
        PixelFont.draw(title, in: &canvas, x: left, y: 2, color: text)
        if let subtitleText { PixelFont.draw(subtitleText, in: &canvas, x: left, y: 8, color: Pixel.mix(text, fill, 0.35)) }
        return canvas
    }

    /// The sign hung over an office's door: centred on the point it's drawn at.
    func sign(_ title: String, subtitle: String?, bar: UInt32) -> OfficeSprite? {
        sprite("sign-\(title)-\(subtitle ?? "")-\(bar)") {
            let canvas = plate(title, subtitle: subtitle, fill: Pixel.rgb(0xFFFDF6), text: Pixel.rgb(0x0B0B0D), bar: bar)
            return canvas.image.map { OfficeSprite(image: $0, dx: -canvas.width / 2, dy: -canvas.height / 2) }
        }
    }

    /// "Back later", hanging on the owner's shut door.
    func backLater() -> OfficeSprite? {
        sprite("back-later") {
            let card = plate(String(localized: "Back later"), fill: Pixel.rgb(Swatch.amber.hex), text: Pixel.rgb(0x0B0B0D), bar: nil)
            var hung = PixelCanvas(width: card.width, height: card.height + 5)
            hung.line((card.width / 2, 0), (3, 5), Pixel.outline)
            hung.line((card.width / 2, 0), (card.width - 4, 5), Pixel.outline)
            hung.draw(card, x: 0, y: 5)
            return hung.image.map { OfficeSprite(image: $0, dx: -hung.width / 2, dy: -hung.height / 2) }
        }
    }

    /// A name tag: a dark pill with the name and a dot in the board's colour. Its top centre is the point.
    func nameTag(_ name: String, dot: UInt32?) -> OfficeSprite? {
        sprite("tag-\(name)-\(dot ?? 0)") {
            let text = PixelFont.fitting(name, width: 40)
            let textWidth = PixelFont.width(text)
            // Seven pixels high, so tags at neighbouring desks (eight apart) never overlap.
            let width = textWidth + (dot != nil ? 8 : 4), height = 7
            var canvas = PixelCanvas(width: width, height: height)
            let fill = Pixel.rgb(0x0B0B0D, alpha: 0xE6)
            canvas.fill(x: 1, y: 0, width: width - 2, height: height, fill)
            canvas.fill(x: 0, y: 1, width: 1, height: height - 2, fill)
            canvas.fill(x: width - 1, y: 1, width: 1, height: height - 2, fill)
            var left = 2
            if let dot {
                canvas.fill(x: 2, y: 2, width: 3, height: 3, dot)
                left = 6
            }
            PixelFont.draw(text, in: &canvas, x: left, y: 1, color: Pixel.rgb(0xF5F2EC))
            return canvas.image.map { OfficeSprite(image: $0, dx: -width / 2, dy: 0) }
        }
    }

    /// A speech balloon: paper, edged in ink (or the board's colour when it needs you), its tail at
    /// the point.
    func balloon(_ label: String, edge: UInt32) -> OfficeSprite? {
        sprite("balloon-\(label)-\(edge)") {
            let text = PixelFont.fitting(label, width: 110)
            let width = PixelFont.width(text) + 7, box = 11
            var canvas = PixelCanvas(width: width, height: box + 3)
            let paper = Pixel.rgb(0xFFFDF6)
            canvas.fill(x: 1, y: 1, width: width - 2, height: box - 2, paper)
            for x in 1..<(width - 1) { canvas[x, 0] = edge; canvas[x, box - 1] = edge }
            for y in 1..<(box - 1) { canvas[0, y] = edge; canvas[width - 1, y] = edge }
            let middle = width / 2
            canvas[middle - 1, box - 1] = paper; canvas[middle, box - 1] = paper; canvas[middle + 1, box - 1] = paper
            canvas[middle - 2, box - 1] = edge; canvas[middle + 2, box - 1] = edge
            canvas[middle - 1, box] = edge; canvas[middle, box] = paper; canvas[middle + 1, box] = edge
            canvas[middle, box + 1] = edge
            PixelFont.draw(text, in: &canvas, x: 4, y: 3, color: Pixel.rgb(0x0B0B0D))
            return canvas.image.map { OfficeSprite(image: $0, dx: -middle, dy: -(box + 2)) }
        }
    }

    /// "+3", in a zone's colour: people with no desk free.
    func badge(_ text: String, fill: UInt32) -> OfficeSprite? {
        sprite("badge-\(text)-\(fill)") {
            let canvas = plate(text, fill: fill, text: Pixel.rgb(0x0B0B0D), bar: nil)
            return canvas.image.map { OfficeSprite(image: $0, dx: -canvas.width / 2, dy: -canvas.height / 2) }
        }
    }

    /// A shadow under someone walking.
    func shadow() -> OfficeSprite? {
        sprite("shadow") {
            var canvas = PixelCanvas(width: 10, height: 4)
            canvas.ellipse(x: 0, y: 0, width: 10, height: 4, 0x38000000)
            return canvas.image.map { OfficeSprite(image: $0, dx: -5, dy: -2) }
        }
    }

    /// The wall clock, by the minute.
    func clock(hour: Int, minute: Int) -> OfficeSprite? {
        sprite("clock-\(hour % 12)-\(minute)") {
            var canvas = PixelCanvas(width: 11, height: 11)
            canvas.ellipse(x: 1, y: 1, width: 9, height: 9, Pixel.rgb(0xFFFDF6))
            canvas.outline(Pixel.outline)
            let minuteAngle = Double(minute) / 60 * 2 * .pi
            let hourAngle = (Double(hour % 12) + Double(minute) / 60) / 12 * 2 * .pi
            canvas.line((5, 5), (5 + Int((sin(minuteAngle) * 3.6).rounded()), 5 - Int((cos(minuteAngle) * 3.6).rounded())), Pixel.outline)
            canvas.line((5, 5), (5 + Int((sin(hourAngle) * 2.2).rounded()), 5 - Int((cos(hourAngle) * 2.2).rounded())), Pixel.rgb(Swatch.ember.hex))
            return canvas.image.map { OfficeSprite(image: $0, dx: -5, dy: -5) }
        }
    }

    // MARK: People

    func person(_ look: OfficeLook, _ pose: OfficeSprites.Pose, mirrored: Bool, tint: UInt32?) -> CGImage? {
        let key = "\(look)-\(pose)-\(mirrored)-\(tint ?? 0)"
        if let image = people[key] { return image }
        var canvas = PixelCanvas(width: OfficeSprites.width, height: OfficeSprites.height)
        for (index, color) in OfficeSprites.rgba(look, pose, mirrored: mirrored).enumerated() where color != 0 {
            canvas[index % OfficeSprites.width, index / OfficeSprites.width] = 0xFF000000 | color
        }
        if let tint { canvas = canvas.tinted(tint) }
        let image = canvas.image
        if people.count > 4000 { people.removeAll() }
        people[key] = image
        return image
    }

    // MARK: The HUD

    /// A HUD chip: an ink box with an icon and text, in pixels. `scale` makes the text bigger.
    func chip(_ text: String, color: UInt32, icon: Icon? = nil, dot: UInt32? = nil, scale: Int = 1) -> CGImage? {
        sprite("chip-\(text)-\(color)-\(String(describing: icon))-\(dot ?? 0)-\(scale)") {
            let textWidth = PixelFont.width(text, scale: scale)
            let iconWidth = icon != nil ? 5 * scale + 3 : dot != nil ? 5 : 0
            let height = PixelFont.height * scale + 6
            let width = textWidth + iconWidth + (text.isEmpty ? 5 : 8)
            var canvas = PixelCanvas(width: width, height: height)
            let fill = Pixel.rgb(0x0B0B0D, alpha: 0xE6)
            canvas.fill(x: 1, y: 0, width: width - 2, height: height, fill)
            canvas.fill(x: 0, y: 1, width: width, height: height - 2, fill)
            var left = 4
            if let icon {
                let top = (height - 5 * scale) / 2
                for (row, line) in icon.rows.enumerated() {
                    for (column, mark) in line.enumerated() where mark == "#" {
                        canvas.fill(x: left + column * scale, y: top + row * scale, width: scale, height: scale, color)
                    }
                }
                left += iconWidth
            } else if let dot {
                let top = (height - 3) / 2
                canvas.fill(x: left, y: top, width: 3, height: 3, dot)
                left += 5
            }
            PixelFont.draw(text, in: &canvas, x: left, y: 3, color: color, scale: scale)
            return canvas.image.map { OfficeSprite(image: $0, dx: 0, dy: 0) }
        }?.image
    }

    /// Lines of pixel text on an ink panel: the message feed.
    func panel(_ lines: [[(String, UInt32)]], title: String) -> CGImage? {
        let key = "panel-\(title)-" + lines.map { $0.map { "\($0.0)|\($0.1)" }.joined(separator: ",") }.joined(separator: ";")
        return sprite(key) {
            let rowHeight = PixelFont.height + 3
            let widths = lines.map { line in line.map { PixelFont.width($0.0) }.reduce(0, +) + max(0, line.count - 1) * 4 }
            let width = max(widths.max() ?? 0, PixelFont.width(title)) + 10
            let height = rowHeight * (lines.count + 1) + 6
            var canvas = PixelCanvas(width: width, height: height)
            let fill = Pixel.rgb(0x0B0B0D, alpha: 0xE6)
            canvas.fill(x: 1, y: 0, width: width - 2, height: height, fill)
            canvas.fill(x: 0, y: 1, width: width, height: height - 2, fill)
            PixelFont.draw(title, in: &canvas, x: 5, y: 4, color: Pixel.rgb(0x8A8790))
            for (index, line) in lines.enumerated() {
                var x = 5
                for (text, color) in line {
                    PixelFont.draw(text, in: &canvas, x: x, y: 4 + rowHeight * (index + 1), color: color)
                    x += PixelFont.width(text) + 4
                }
            }
            return canvas.image.map { OfficeSprite(image: $0, dx: 0, dy: 0) }
        }?.image
    }

    /// Five-pixel icons for the HUD.
    enum Icon: String, CustomStringConvertible {
        case people, rack, sun, moon

        var description: String { rawValue }

        var rows: [String] {
            switch self {
            case .people: ["..#..", ".###.", "#.#.#", "..#..", ".#.#."]
            case .rack: ["#####", "#.#.#", "#####", "#.#.#", "#####"]
            case .sun: ["#.#.#", ".###.", "#####", ".###.", "#.#.#"]
            case .moon: [".###.", "##...", "##...", "##...", ".###."]
            }
        }
    }
}
