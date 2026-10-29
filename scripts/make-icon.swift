// Renders Software Factory's app icons into the asset catalogs, the Mac app's and the iPhone app's,
// in the family style of Rounds, Sojourny and Emanata: a dark rounded card on a swatch field. On the
// card, a board of status lights in Switchyard's state colors.
// Usage: swift scripts/make-icon.swift
import AppKit

let catalog = URL(fileURLWithPath: "SoftwareFactory/Resources/Assets.xcassets/AppIcon.appiconset")
let phoneCatalog = URL(fileURLWithPath: "Phone/Resources/Assets.xcassets/AppIcon.appiconset")
for folder in [catalog, phoneCatalog] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let amber = color(0xFFC43D), violet = color(0x9466FF), mint = color(0x3EDB98), ember = color(0xFF5533)
let slate = color(0x8C95A8, 0.32)

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

    // The board: a dark card, slightly wide, with a soft shadow.
    let card = CGRect(x: tile.minX + 150 * u, y: tile.minY + 190 * u, width: 724 * u, height: 644 * u)
    let cardShape = NSBezierPath(roundedRect: card, xRadius: 92 * u, yRadius: 92 * u)
    ctx.saveGState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    cardShadow.shadowBlurRadius = 40 * u
    cardShadow.shadowOffset = NSSize(width: 0, height: -14 * u)
    cardShadow.set()
    color(0x1E1E23).setFill()
    cardShape.fill()
    ctx.restoreGState()
    ctx.saveGState()
    cardShape.addClip()
    NSGradient(colors: [color(0x2E2E35), color(0x17171B)])!.draw(in: card, angle: -90)
    ctx.restoreGState()

    // Status lights, three by three: one waiting, two at work, one shipped, one stuck, the rest at rest.
    let lights: [[NSColor]] = [[amber, violet, slate], [slate, mint, violet], [slate, slate, ember]]
    let inset = 70 * u, gap = 36 * u
    let inner = card.insetBy(dx: inset, dy: inset)
    let cell = CGSize(width: (inner.width - gap * 2) / 3, height: (inner.height - gap * 2) / 3)
    for (row, colors) in lights.enumerated() {
        for (column, fill) in colors.enumerated() {
            let rect = CGRect(x: inner.minX + CGFloat(column) * (cell.width + gap),
                              y: inner.maxY - CGFloat(row + 1) * cell.height - CGFloat(row) * gap,
                              width: cell.width, height: cell.height)
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 38 * u, yRadius: 38 * u).fill()
        }
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
