import CoreGraphics
import Foundation

/// The office's people, as 14×18 pixel sprites drawn here in code: chibi figures with big heads, a
/// hat or hair, a dark outline and warm colours, an 8-bit cousin of Glittergem Peaks' townsfolk.
/// Original art: each sprite is a head (one of six styles) on a body (one of the poses), coloured from
/// a look picked by the person's id.
nonisolated enum OfficeSprites {
    static let width = 14
    static let height = 18

    enum Pose: String, CaseIterable, Hashable, Sendable {
        case stand, walk1, walk2, backStand, back1, back2, sit, type1, type2, talk, cheer1, cheer2

        var isBack: Bool { self == .backStand || self == .back1 || self == .back2 }
    }

    /// Head styles, rows 0–8. Keys: K outline, H hat or band, h its shade, L lamp, R hair, r its shade, S skin,
    /// s skin shade, E eye, C cheek.
    static let heads: [OfficeLook.Head: [String]] = [
        .helmet: [
            "....KKKK....",
            "..KKHLHHKK..",
            ".KHHHHHHHhK.",
            "KHHHHHHHHHhK",
            "KKRRRRRRRRKK",
            ".KRSSSSSSRK.",
            ".KSESSSSESK.",
            ".KsCSSSSCsK.",
            "..KKSSSSKK..",
        ],
        .bucket: [
            "...KKKKKK...",
            "..KHHHHHHK..",
            ".KHHhhhhHHK.",
            "KHHHHHHHHHHK",
            "KKRRRRRRRRKK",
            ".KRSSSSSSRK.",
            ".KSESSSSESK.",
            ".KsCSSSSCsK.",
            "..KKSSSSKK..",
        ],
        .short: [
            "...KKKKKK...",
            "..KRRRRRRK..",
            ".KRRRRRRRRK.",
            ".KRRRRRRRrK.",
            ".KRSSRRSSRK.",
            ".KSSSSSSSSK.",
            ".KSESSSSESK.",
            ".KsCSSSSCsK.",
            "..KKSSSSKK..",
        ],
        .long: [
            "...KKKKKK...",
            "..KRRRRRRK..",
            ".KRHHHHHHRK.",
            ".KRRRRRRRRK.",
            "KRRSSSSSSRRK",
            "KRSSSSSSSSRK",
            "KRSESSSSESRK",
            "KRsCSSSSCsRK",
            "KRKKSSSSKKRK",
        ],
        .beanie: [
            ".....KK.....",
            "...KKHHKK...",
            "..KHHHHHHK..",
            ".KHhHhHhHhK.",
            ".KHHHHHHHHK.",
            ".KSSSSSSSSK.",
            ".KSESSSSESK.",
            ".KsCSSSSCsK.",
            "..KKSSSSKK..",
        ],
        .bun: [
            "....KKKK....",
            "...KRRRRK...",
            "..KKRRRRKK..",
            ".KRRRRRRRRK.",
            ".KRRSSSSRRK.",
            ".KSSSSSSSSK.",
            ".KSESSSSESK.",
            ".KsCSSSSCsK.",
            "..KKSSSSKK..",
        ],
    ]

    /// The backs of the heads, for walking away from you.
    static let backs: [OfficeLook.Head: [String]] = [
        .helmet: ["....KKKK....", "..KKHHHHKK..", ".KHHHHHHHhK.", "KHHHHHHHHHhK", "KKRRRRRRRRKK", ".KRRRRRRRRK.", ".KRRRRRRRrK.", ".KRRRRRRRrK.", "..KKRRRRKK.."],
        .bucket: ["...KKKKKK...", "..KHHHHHHK..", ".KHHhhhhHHK.", "KHHHHHHHHHHK", "KKRRRRRRRRKK", ".KRRRRRRRRK.", ".KRRRRRRRrK.", ".KRRRRRRRrK.", "..KKRRRRKK.."],
        .short: ["...KKKKKK...", "..KRRRRRRK..", ".KRRRRRRRRK.", ".KRRRRRRRrK.", ".KRRRRRRRRK.", ".KRRRRRRRRK.", ".KRRRRRRRrK.", ".KsRRRRRRsK.", "..KKSSSSKK.."],
        .long: ["...KKKKKK...", "..KRRRRRRK..", ".KRHHHHHHRK.", ".KRRRRRRRRK.", "KRRRRRRRRRRK", "KRRRRRRRRRRK", "KRRRRRRRRrRK", "KRRRRRRRRrRK", "KRKRRRRRRKRK"],
        .beanie: [".....KK.....", "...KKHHKK...", "..KHHHHHHK..", ".KHhHhHhHhK.", ".KHHHHHHHHK.", ".KRRRRRRRRK.", ".KRRRRRRRrK.", ".KsRRRRRRsK.", "..KKSSSSKK.."],
        .bun: ["....KKKK....", "...KRRRRK...", "..KKRRRRKK..", ".KRRRRRRRRK.", ".KRRRRRRRRK.", ".KRRRRRRRRK.", ".KRRRRRRRrK.", ".KsRRRRRRsK.", "..KKSSSSKK.."],
    ]

    /// Bodies, rows 9–16. Keys: B shirt, b its shade, T tie or badge, P trousers, F shoes.
    static let bodies: [String: [String]] = [
        "stand": ["..KBBBBBBK..", ".KBBTBBBBbK.", ".KSKBTBBKSK.", "..KKPPPPKK..", "...KPPPPK...", "...KPKKPK...", "...KFK.KFK..", "...KK..KK..."],
        "walk1": ["..KBBBBBBK..", ".KBBTBBBBbK.", ".KSKBTBBKSK.", "..KKPPPPKK..", "...KPPPPK...", "..KPPKKPK...", "..KFFK.KFK..", "..KKK..KK..."],
        "walk2": ["..KBBBBBBK..", ".KBBTBBBBbK.", ".KSKBTBBKSK.", "..KKPPPPKK..", "...KPPPPK...", "...KPKKPPK..", "...KFK.KFFK.", "...KK..KKK.."],
        "back": ["..KBBBBBBK..", ".KBBBBBBBbK.", ".KSKBBBBKSK.", "..KKPPPPKK..", "...KPPPPK...", "...KPKKPK...", "...KFK.KFK..", "...KK..KK..."],
        "back1": ["..KBBBBBBK..", ".KBBBBBBBbK.", ".KSKBBBBKSK.", "..KKPPPPKK..", "...KPPPPK...", "..KPPKKPK...", "..KFFK.KFK..", "..KKK..KK..."],
        "back2": ["..KBBBBBBK..", ".KBBBBBBBbK.", ".KSKBBBBKSK.", "..KKPPPPKK..", "...KPPPPK...", "...KPKKPPK..", "...KFK.KFFK.", "...KK..KKK.."],
        "sit": ["..KBBBBBBK..", ".KBBTBBBBbK.", ".KBKBTBBKbK.", ".KSKPPPPKSK.", "..KPPPPPPK..", "..KKKKKKKK..", "............", "............"],
        "type1": ["..KBBBBBBK..", ".KBBTBBBBbK.", "KBBKBTBBKBBK", "KSSKPPPPKKSK", ".KKPPPPPPKK.", "..KKKKKKKK..", "............", "............"],
        "type2": ["..KBBBBBBK..", ".KBBTBBBBbK.", "KBBKBTBBKBBK", "KSKKPPPPKSSK", ".KKPPPPPPKK.", "..KKKKKKKK..", "............", "............"],
        "talk": ["..KBBBBBBK..", ".KBBTBBBBbK.", ".KBKBTBBKbK.", ".KSKPPPPKK..", "..KPPPPPPK..", "..KKKKKKKK..", "............", "............"],
        "cheer": ["..KBBBBBBK..", "..KBBTBBbK..", "...KBTBBK...", "..KKPPPPKK..", "...KPPPPK...", "...KPKKPK...", "...KFK.KFK..", "...KK..KK..."],
    ]

    /// Both arms up, each side mirrored: (x, y, key).
    static let armsUp: [(Int, Int, Character)] = [
        (0, 0, "K"), (1, 0, "K"), (0, 1, "K"), (1, 1, "S"), (0, 2, "K"), (1, 2, "S"), (2, 2, "K"),
        (1, 3, "K"), (2, 3, "B"), (1, 4, "K"), (2, 4, "B"), (1, 5, "K"), (2, 5, "B"), (1, 6, "K"), (2, 6, "B"),
        (1, 7, "K"), (2, 7, "B"), (1, 8, "K"), (2, 8, "B"), (1, 9, "K"), (2, 9, "B"), (2, 10, "B"), (2, 11, "B"),
    ]

    /// One hand up, as people do when they talk.
    static let handUp: [(Int, Int, Character)] = [
        (11, 4, "K"), (12, 4, "K"), (11, 5, "K"), (12, 5, "S"), (13, 5, "K"), (11, 6, "K"), (12, 6, "S"), (13, 6, "K"),
        (12, 7, "K"), (13, 7, "B"), (12, 8, "K"), (13, 8, "B"), (12, 9, "K"), (13, 9, "B"), (12, 10, "K"), (13, 10, "B"),
        (12, 11, "B"), (13, 11, "K"),
    ]

    /// A sprite's pixels as palette keys, row by row ("." is clear).
    static func pixels(_ head: OfficeLook.Head, _ pose: Pose) -> [[Character]] {
        var grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
        let headRows = pose.isBack ? backs[head]! : heads[head]!
        let body: [String]
        var bob = 0
        var arms: [(Int, Int, Character)] = []
        var mirrorsArms = false
        switch pose {
        case .stand: body = bodies["stand"]!
        case .walk1: body = bodies["walk1"]!
        case .walk2: body = bodies["walk2"]!
        case .backStand: body = bodies["back"]!
        case .back1: body = bodies["back1"]!
        case .back2: body = bodies["back2"]!
        case .sit: body = bodies["sit"]!; bob = 1
        case .type1: body = bodies["type1"]!; bob = 1
        case .type2: body = bodies["type2"]!; bob = 1
        case .talk: body = bodies["talk"]!; bob = 1; arms = handUp
        case .cheer1: body = bodies["cheer"]!; arms = armsUp; mirrorsArms = true
        case .cheer2: body = bodies["cheer"]!; bob = 1; arms = armsUp; mirrorsArms = true
        }
        for (row, line) in (headRows + body).enumerated() {
            for (column, key) in line.enumerated() where key != "." {
                let y = row + 1 + bob
                if y < height { grid[y][column + 1] = key }
            }
        }
        for (x, y, key) in arms {
            let row = y + bob
            guard row < height else { continue }
            grid[row][x] = key
            if mirrorsArms { grid[row][width - 1 - x] = key }
        }
        return grid
    }

    /// RGBA pixels for a look in a pose, optionally mirrored.
    static func rgba(_ look: OfficeLook, _ pose: Pose, mirrored: Bool = false) -> [UInt32] {
        let grid = pixels(look.head, pose)
        var out = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let key = grid[y][mirrored ? width - 1 - x : x]
                if let color = look.color(for: key) { out[y * width + x] = color }
            }
        }
        return out
    }

    /// The sprite as an image, one pixel per pixel: draw it scaled up without smoothing.
    static func image(_ look: OfficeLook, _ pose: Pose, mirrored: Bool = false) -> CGImage? {
        let pixels = rgba(look, pose, mirrored: mirrored)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (index, color) in pixels.enumerated() where color != 0 {
            bytes[index * 4] = UInt8((color >> 16) & 0xFF)
            bytes[index * 4 + 1] = UInt8((color >> 8) & 0xFF)
            bytes[index * 4 + 2] = UInt8(color & 0xFF)
            bytes[index * 4 + 3] = 0xFF
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// How someone looks: a head style and colours, picked from their id so they look the same every time.
nonisolated struct OfficeLook: Hashable, Sendable {
    enum Head: Int, CaseIterable, Hashable, Sendable { case helmet, bucket, short, long, beanie, bun }
    enum Accent: Hashable, Sendable { case none, tie, badge }

    var head: Head
    var skin: UInt32
    var hair: UInt32
    var hat: UInt32
    var shirt: UInt32
    var trousers: UInt32
    var accent: Accent

    static let outline: UInt32 = 0x2B1B22
    static let skins: [UInt32] = [0xF5C7A0, 0xE8AF84, 0xC98A5E, 0x9C6440, 0x6E4329]
    static let hairs: [UInt32] = [0x7A4528, 0x3A2A33, 0xC0602C, 0xE2B04A, 0xA8A0A8, 0x2E3550, 0x8C3B4A]
    static let hats: [UInt32] = [0x9A9A3A, 0x3E8E7E, 0xD9534F, 0x4F6BD8, 0xE8A33C, 0x8D5BB8, 0x5BA35B]
    static let shirts: [UInt32] = [0x2FA59A, 0xE0557F, 0x5468FF, 0x8DBF2E, 0xB84FD0, 0xF29C38, 0x3C9BE0, 0xD9D2C2, 0xC94F3D]
    static let trousersColors: [UInt32] = [0x3E4C9A, 0x5A3A2A, 0x3A3A48, 0x6B6B3A]

    /// The owner: a miner's hard hat with a lamp, and overalls.
    static let owner = OfficeLook(head: .helmet, skin: 0xF5C7A0, hair: 0x7A4528, hat: 0xFFC43D, shirt: 0x2FA59A, trousers: 0x3E4C9A, accent: .none)

    static func look(for id: String, role: OfficePerson.Role) -> OfficeLook {
        if role == .owner { return owner }
        var seed = OfficeNames.hash(id)
        func pick<T>(_ list: [T]) -> T {
            let value = list[Int(seed % UInt64(list.count))]
            seed = seed / UInt64(list.count) &+ 0x9E3779B97F4A7C15 &* (seed & 0xFF)
            return value
        }
        // Hard hats are the owner's.
        let head = pick([Head.bucket, .short, .long, .beanie, .bun, .short, .long])
        return OfficeLook(head: head, skin: pick(skins), hair: pick(hairs), hat: pick(hats), shirt: pick(shirts),
                          trousers: pick(trousersColors), accent: role == .lead ? .tie : role == .workflow ? .badge : .none)
    }

    func color(for key: Character) -> UInt32? {
        switch key {
        case "K", "E": Self.outline
        case "H": hat
        case "h": Self.shade(hat)
        case "L": 0xFFF6C8
        case "R": hair
        case "r": Self.shade(hair, by: 0.25)
        case "S": skin
        case "s": Self.shade(skin, by: 0.12)
        case "C": 0xF08A7A
        case "B": shirt
        case "b": Self.shade(shirt)
        case "T":
            switch accent {
            case .none: shirt
            case .tie: 0x8C2335
            case .badge: 0xF5F2EC
            }
        case "P": trousers
        case "F": 0x4A2A1E
        default: nil
        }
    }

    /// A darker version of a colour, for shading.
    static func shade(_ color: UInt32, by amount: Double = 0.22) -> UInt32 {
        let r = Double((color >> 16) & 0xFF) * (1 - amount)
        let g = Double((color >> 8) & 0xFF) * (1 - amount)
        let b = Double(color & 0xFF) * (1 - amount)
        return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }
}
