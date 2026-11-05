import CoreGraphics
import Foundation

/// A grid of pixels to paint the office's pixel art into, at one pixel per pixel: polygons filled by
/// the pixel-centre rule (so 2:1 isometric edges come out as clean two-pixel steps), lines, a dark
/// outline around a sprite's silhouette like the characters', shearing onto a wall's slant, and an
/// image to draw scaled up without smoothing. Colours are 0xAARRGGBB; alpha 0 is clear.
nonisolated struct PixelCanvas: Sendable {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt32]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        pixels = Array(repeating: 0, count: self.width * self.height)
    }

    subscript(x: Int, y: Int) -> UInt32 {
        get { x >= 0 && y >= 0 && x < width && y < height ? pixels[y * width + x] : 0 }
        set { if x >= 0 && y >= 0 && x < width && y < height { pixels[y * width + x] = newValue } }
    }

    /// Paints a pixel, mixing in a colour that isn't opaque.
    mutating func plot(_ x: Int, _ y: Int, _ color: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let alpha = color >> 24
        if alpha == 0xFF { pixels[y * width + x] = color; return }
        if alpha == 0 { return }
        let under = pixels[y * width + x]
        pixels[y * width + x] = Pixel.over(color, under)
    }

    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, _ color: UInt32) {
        guard w > 0, h > 0 else { return }
        for row in max(0, y)..<min(height, y + h) {
            for column in max(0, x)..<min(width, x + w) { plot(column, row, color) }
        }
    }

    /// Fills a polygon: every pixel whose centre is inside.
    mutating func fill(_ points: [CGPoint], _ color: UInt32) {
        guard points.count >= 3 else { return }
        let ys = points.map(\.y)
        let top = max(0, Int(floor(ys.min()!))), bottom = min(height - 1, Int(ceil(ys.max()!)))
        guard top <= bottom else { return }
        for y in top...bottom {
            let centre = Double(y) + 0.5
            var crossings: [Double] = []
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                if (a.y <= centre && b.y > centre) || (b.y <= centre && a.y > centre) {
                    crossings.append(a.x + (centre - a.y) / (b.y - a.y) * (b.x - a.x))
                }
            }
            crossings.sort()
            var index = 0
            while index + 1 < crossings.count {
                let start = max(0, Int(ceil(crossings[index] - 0.5)))
                let end = min(width - 1, Int(ceil(crossings[index + 1] - 0.5)) - 1)
                if start <= end { for x in start...end { plot(x, y, color) } }
                index += 2
            }
        }
    }

    /// A one-pixel line between pixels.
    mutating func line(_ from: (Int, Int), _ to: (Int, Int), _ color: UInt32) {
        var (x, y) = from
        let dx = abs(to.0 - x), dy = -abs(to.1 - y)
        let sx = x < to.0 ? 1 : -1, sy = y < to.1 ? 1 : -1
        var error = dx + dy
        while true {
            plot(x, y, color)
            if x == to.0 && y == to.1 { return }
            let twice = 2 * error
            if twice >= dy { error += dy; x += sx }
            if twice <= dx { error += dx; y += sy }
        }
    }

    /// A filled ellipse in a box.
    mutating func ellipse(x: Int, y: Int, width w: Int, height h: Int, _ color: UInt32) {
        let rx = Double(w) / 2, ry = Double(h) / 2
        let cx = Double(x) + rx, cy = Double(y) + ry
        for row in y..<(y + h) {
            for column in x..<(x + w) {
                let nx = (Double(column) + 0.5 - cx) / rx, ny = (Double(row) + 0.5 - cy) / ry
                if nx * nx + ny * ny <= 1.0 { plot(column, row, color) }
            }
        }
    }

    /// A dark line around the silhouette: every clear pixel next to a solid one.
    mutating func outline(_ color: UInt32) {
        let source = pixels
        func solid(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && source[y * width + x] >> 24 >= 0x80
        }
        for y in 0..<height {
            for x in 0..<width where source[y * width + x] >> 24 == 0 {
                if solid(x - 1, y) || solid(x + 1, y) || solid(x, y - 1) || solid(x, y + 1) { pixels[y * width + x] = color }
            }
        }
    }

    /// Another canvas painted on top, its top-left at (x, y).
    mutating func draw(_ other: PixelCanvas, x: Int, y: Int) {
        for row in 0..<other.height {
            for column in 0..<other.width {
                let color = other.pixels[row * other.width + column]
                if color >> 24 != 0 { plot(x + column, y + row, color) }
            }
        }
    }

    /// The canvas slanted onto a wall: each column two pixels on moves a pixel down (`falling`, a wall
    /// running along x) or up (a wall running along y), as isometric edges do.
    func sheared(falling: Bool) -> PixelCanvas {
        let extra = (width - 1) / 2
        var out = PixelCanvas(width: width, height: height + extra)
        for x in 0..<width {
            let shift = falling ? x / 2 : extra - x / 2
            for y in 0..<height { out[x, y + shift] = pixels[y * width + x] }
        }
        return out
    }

    /// Every colour multiplied by another: night light.
    func tinted(_ tint: UInt32) -> PixelCanvas {
        var out = self
        out.pixels = pixels.map { $0 >> 24 == 0 ? 0 : Pixel.multiply($0, tint) }
        return out
    }

    var image: CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, color) in pixels.enumerated() where color >> 24 != 0 {
            let alpha = Double(color >> 24) / 255
            bytes[index * 4] = UInt8(Double((color >> 16) & 0xFF) * alpha)
            bytes[index * 4 + 1] = UInt8(Double((color >> 8) & 0xFF) * alpha)
            bytes[index * 4 + 2] = UInt8(Double(color & 0xFF) * alpha)
            bytes[index * 4 + 3] = UInt8(color >> 24)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Colours as 0xAARRGGBB.
nonisolated enum Pixel {
    static let clear: UInt32 = 0
    /// The characters' outline: a dark plum.
    static let outline: UInt32 = 0xFF2B1B22

    static func rgb(_ hex: UInt32, alpha: UInt32 = 0xFF) -> UInt32 { alpha << 24 | (hex & 0xFFFFFF) }

    static func channels(_ color: UInt32) -> (Double, Double, Double, Double) {
        (Double((color >> 16) & 0xFF), Double((color >> 8) & 0xFF), Double(color & 0xFF), Double(color >> 24) / 255)
    }

    static func make(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(255, value.rounded()))) }
        return byte(a * 255) << 24 | byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// `top` over `bottom`.
    static func over(_ top: UInt32, _ bottom: UInt32) -> UInt32 {
        let (r1, g1, b1, a1) = channels(top), (r2, g2, b2, a2) = channels(bottom)
        let a = a1 + a2 * (1 - a1)
        guard a > 0 else { return 0 }
        return make((r1 * a1 + r2 * a2 * (1 - a1)) / a, (g1 * a1 + g2 * a2 * (1 - a1)) / a, (b1 * a1 + b2 * a2 * (1 - a1)) / a, a)
    }

    /// Between two colours: 0 is `a`, 1 is `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let (r1, g1, b1, a1) = channels(a), (r2, g2, b2, a2) = channels(b)
        return make(r1 + (r2 - r1) * amount, g1 + (g2 - g1) * amount, b1 + (b2 - b1) * amount, a1 + (a2 - a1) * amount)
    }

    static func multiply(_ color: UInt32, _ tint: UInt32) -> UInt32 {
        let (r, g, b, a) = channels(color), (tr, tg, tb, _) = channels(tint)
        return make(r * tr / 255, g * tg / 255, b * tb / 255, a)
    }

    static func shade(_ color: UInt32, _ amount: Double = 0.2) -> UInt32 { mix(color, 0xFF000000, amount) }
    static func light(_ color: UInt32, _ amount: Double = 0.2) -> UInt32 { mix(color, 0xFFFFFFFF, amount) }
}

/// The office's lettering: a hand-made 8-bit font, capitals five pixels high, so signs, name tags,
/// balloons and the HUD look like the characters. Lowercase is set in capitals.
nonisolated enum PixelFont {
    static let height = 5

    private static let glyphs: [Character: [String]] = [
        "A": [".##.", "#..#", "####", "#..#", "#..#"],
        "B": ["###.", "#..#", "###.", "#..#", "###."],
        "C": [".###", "#...", "#...", "#...", ".###"],
        "D": ["###.", "#..#", "#..#", "#..#", "###."],
        "E": ["####", "#...", "###.", "#...", "####"],
        "F": ["####", "#...", "###.", "#...", "#..."],
        "G": [".###", "#...", "#.##", "#..#", ".###"],
        "H": ["#..#", "#..#", "####", "#..#", "#..#"],
        "I": ["###", ".#.", ".#.", ".#.", "###"],
        "J": ["...#", "...#", "...#", "#..#", ".##."],
        "K": ["#..#", "#.#.", "##..", "#.#.", "#..#"],
        "L": ["#...", "#...", "#...", "#...", "####"],
        "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
        "N": ["#..#", "##.#", "#.##", "#..#", "#..#"],
        "O": [".##.", "#..#", "#..#", "#..#", ".##."],
        "P": ["###.", "#..#", "###.", "#...", "#..."],
        "Q": [".##.", "#..#", "#..#", "#.#.", ".#.#"],
        "R": ["###.", "#..#", "###.", "#.#.", "#..#"],
        "S": [".###", "#...", ".##.", "...#", "###."],
        "T": ["###", ".#.", ".#.", ".#.", ".#."],
        "U": ["#..#", "#..#", "#..#", "#..#", ".##."],
        "V": ["#...#", "#...#", ".#.#.", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#.#.#", "##.##", "#...#"],
        "X": ["#..#", "#..#", ".##.", "#..#", "#..#"],
        "Y": ["#.#", "#.#", ".#.", ".#.", ".#."],
        "Z": ["####", "...#", ".##.", "#...", "####"],
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###.", "...#", ".##.", "#...", "####"],
        "3": ["###.", "...#", ".##.", "...#", "###."],
        "4": ["#..#", "#..#", "####", "...#", "...#"],
        "5": ["####", "#...", "###.", "...#", "###."],
        "6": [".##.", "#...", "###.", "#..#", ".##."],
        "7": ["####", "...#", "..#.", ".#..", ".#.."],
        "8": [".##.", "#..#", ".##.", "#..#", ".##."],
        "9": [".##.", "#..#", ".###", "...#", ".##."],
        ".": [".", ".", ".", ".", "#"],
        ",": ["..", "..", "..", ".#", "#."],
        ":": [".", "#", ".", "#", "."],
        ";": ["..", ".#", "..", ".#", "#."],
        "-": ["...", "...", "###", "...", "..."],
        "+": ["...", ".#.", "###", ".#.", "..."],
        "=": ["...", "###", "...", "###", "..."],
        "?": ["###", "..#", ".##", "...", ".#."],
        "!": ["#", "#", "#", ".", "#"],
        "'": ["#", "#", ".", ".", "."],
        "\"": ["#.#", "#.#", "...", "...", "..."],
        "/": ["..#", "..#", ".#.", "#..", "#.."],
        "(": [".#", "#.", "#.", "#.", ".#"],
        ")": ["#.", ".#", ".#", ".#", "#."],
        "&": [".#..", "#.#.", ".#..", "#.#.", ".#.#"],
        "#": [".#.#.", "#####", ".#.#.", "#####", ".#.#."],
        "%": ["#..#", "..#.", ".#..", "#...", "#..#"],
        "_": ["...", "...", "...", "...", "###"],
        "·": [".", ".", "#", ".", "."],
        "→": ["..#.", "...#", "####", "...#", "..#."],
        "←": [".#..", "#...", "####", "#...", ".#.."],
        "@": [".##.", "#.##", "#.##", "#...", ".###"],
        "*": ["...", "#.#", ".#.", "#.#", "..."],
    ]

    /// Capitals, without accents; "…" as three dots. Characters it has no glyph for become "?".
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "…", with: "...")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
    }

    private static func glyph(_ character: Character) -> [String]? {
        if character.isWhitespace { return nil }
        return glyphs[character] ?? glyphs["?"]
    }

    /// How wide `text` is, in pixels, at a scale.
    static func width(_ text: String, scale: Int = 1) -> Int {
        let characters = Array(normalized(text))
        guard !characters.isEmpty else { return 0 }
        let widths = characters.map { glyph($0)?.first?.count ?? 3 }
        return (widths.reduce(0, +) + characters.count - 1) * scale
    }

    /// Paints `text` with its top-left at (x, y). A `slope` of 1 steps each letter down half its
    /// distance along (-1, up), so lettering follows an isometric edge with every letter whole.
    static func draw(_ text: String, in canvas: inout PixelCanvas, x: Int, y: Int, color: UInt32, scale: Int = 1, slope: Int = 0) {
        var cursor = x
        for character in normalized(text) {
            guard let rows = glyph(character) else { cursor += 4 * scale; continue }
            let drop = slope * (cursor - x) / 2
            for (row, line) in rows.enumerated() {
                for (column, mark) in line.enumerated() where mark == "#" {
                    canvas.fill(x: cursor + column * scale, y: y + drop + row * scale, width: scale, height: scale, color)
                }
            }
            cursor += ((rows.first?.count ?? 3) + 1) * scale
        }
    }

    /// `text` cut to fit `width` pixels at a word's end where it can ("Software Factory" to
    /// "Software"), else with "...": for names on signs and skirting.
    static func fittingWords(_ text: String, width limit: Int) -> String {
        guard width(text) > limit else { return text }
        var words = text.split(separator: " ").map(String.init)
        while words.count > 1 {
            words.removeLast()
            let shorter = words.joined(separator: " ")
            if width(shorter) <= limit { return shorter }
        }
        return fitting(text, width: limit)
    }

    /// `text` cut to fit `width` pixels, with "..." when it's cut.
    static func fitting(_ text: String, width limit: Int) -> String {
        guard width(text) > limit else { return text }
        var characters = Array(normalized(text))
        while !characters.isEmpty, width(String(characters) + "...") > limit { characters.removeLast() }
        return String(characters).trimmingCharacters(in: .whitespaces) + "..."
    }
}
