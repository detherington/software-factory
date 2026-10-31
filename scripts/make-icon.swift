// Renders Software Factory's app icons into the asset catalogs, the Mac app's and the iPhone app's,
// in the family style of Rounds, Sojourny and Emanata: a dark shape on a swatch field. Here the shape is
// a factory, with a sawtooth roof and a chimney, and its windows are lit in Switchyard's state colors.
// (A card with a grid of lights looked like a calendar, and too like Emanata's comic page.)
// Usage: swift scripts/make-icon.swift
import AppKit

let catalog = URL(fileURLWithPath: "SoftwareFactory/Resources/Assets.xcassets/AppIcon.appiconset")
let phoneCatalog = URL(fileURLWithPath: "Phone/Resources/Assets.xcassets/AppIcon.appiconset")
for folder in [catalog, phoneCatalog] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let amber = color(0xFFC43D), violet = color(0x9466FF), mint = color(0x3EDB98)

/// Draws the artwork into a square of `side` pixels. `macShape` insets it into the macOS rounded-rect
/// footprint; the iPhone's icon is full-bleed and masked by the system.
func render(side: Int, macShape: Bool = true) -> Data {
    let s = CGFloat(side)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    var tile = CGRect(x: 0, y: 0, width: s, height: s)
    if macShape { tile = tile.insetBy(dx: s * 0.098, dy: s * 0.098) }
    let radius = macShape ? tile.width * 0.225 : 0
    let tileShape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    if macShape {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = s * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
        shadow.set()
        NSColor.black.setFill()
        tileShape.fill()
        NSShadow().set()
    }

    ctx.saveGState()
    tileShape.addClip()
    let u = tile.width / 1024 // design units

    // Field: lime, lighter at the top. Emanata has violet and Sojourny cobalt, and lime means no
    // state on the board.
    NSGradient(colors: [color(0xC1E75A), color(0xA3CC35)])!.draw(in: tile, angle: -90)

    // The factory: three bays under a sawtooth roof, each with its steep face to the right, and a
    // chimney. Soft at the base, sharp at the roof.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * u, y: tile.minY + y * u) }
    let left: CGFloat = 150, right: CGFloat = 874, base: CGFloat = 190, eave: CGFloat = 610, peak: CGFloat = 790
    let bay = (right - left) / 3
    let factory = NSBezierPath()
    factory.move(to: p(left, eave))
    factory.appendArc(from: p(left, base), to: p(right, base), radius: 44 * u)
    factory.appendArc(from: p(right, base), to: p(right, peak), radius: 44 * u)
    factory.line(to: p(right, peak))
    for bayIndex in (0..<3).reversed() {
        let x = left + CGFloat(bayIndex) * bay
        factory.line(to: p(x, eave))
        if bayIndex > 0 { factory.line(to: p(x, peak)) }
    }
    factory.close()
    factory.append(NSBezierPath(roundedRect: CGRect(origin: p(left + 50, eave - 40), size: CGSize(width: 76 * u, height: 330 * u)),
                                xRadius: 16 * u, yRadius: 16 * u))
    let bounds = CGRect(origin: p(left, base), size: CGSize(width: (right - left) * u, height: 710 * u))
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 40 * u
    shadow.shadowOffset = NSSize(width: 0, height: -14 * u)
    shadow.set()
    color(0x1E1E23).setFill()
    factory.fill()
    ctx.restoreGState()
    ctx.saveGState()
    factory.addClip()
    NSGradient(colors: [color(0x2E2E35), color(0x17171B)])!.draw(in: bounds, angle: -90)
    ctx.restoreGState()

    // A tall window in each bay, lit: one waiting on you, one at work, one shipped.
    for (bayIndex, light) in [amber, violet, mint].enumerated() {
        let x = left + CGFloat(bayIndex) * bay
        let window = CGRect(origin: p(x + bay * 0.24, 270), size: CGSize(width: bay * 0.52 * u, height: 260 * u))
        ctx.saveGState()
        let glow = NSShadow()
        glow.shadowColor = light.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 36 * u
        glow.set()
        light.setFill()
        NSBezierPath(roundedRect: window, xRadius: 34 * u, yRadius: 34 * u).fill()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-mac-\(points)@\(scale)x.png"
        try render(side: points * scale).write(to: catalog.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

func writeContents(_ images: [[String: String]], to folder: URL) throws {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: folder.appendingPathComponent("Contents.json"))
}
try writeContents(images, to: catalog)

// The iPhone's: one 1024-point image, which iOS scales.
try render(side: 1024, macShape: false).write(to: phoneCatalog.appendingPathComponent("icon-ios-1024.png"))
try writeContents([["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-ios-1024.png"]], to: phoneCatalog)
print("Wrote \(images.count) Mac icon images and the iPhone's")
