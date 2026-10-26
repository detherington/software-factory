import SwiftUI

/// The "Switchyard" design system: Rounds' Signal and Sojourny's Wayfinding pointed at a board of
/// projects. Near-black surfaces, warm off-white type, giant compressed codes and counts, wide tracked
/// labels. Color means a project's state, everywhere. Glass is for controls; content stays opaque.
enum Switchyard {
    static let background = Color(hex: 0x0B0B0D)
    static let surface = Color(hex: 0x151518)
    static let surfaceRaised = Color(hex: 0x1E1E23)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color(hex: 0xF5F2EC)
    static let textSecondary = Color(hex: 0xF5F2EC).opacity(0.62)
    /// 54%: the least that keeps small text at 4.5:1 on every surface.
    static let textTertiary = Color(hex: 0xF5F2EC).opacity(0.54)
    /// Dark text on the bright swatches (WCAG contrast picks it for every one of them).
    static let ink = Color(hex: 0x0B0B0D)
    /// Violet: the app's tint, and a project being worked on right now.
    static let accent = Swatch.violet.color

    static let cardRadius: CGFloat = 22
}

/// The shared Signal palette.
enum Swatch: String, CaseIterable, Identifiable, Codable, Sendable {
    case ember, tangerine, amber, lime, mint, tide, sky, cobalt, violet, orchid, rose, slate

    var id: Self { self }

    var hex: UInt32 {
        switch self {
        case .ember: 0xFF5533
        case .tangerine: 0xFF8C1A
        case .amber: 0xFFC43D
        case .lime: 0xB5E33B
        case .mint: 0x3EDB98
        case .tide: 0x1FC7B6
        case .sky: 0x45AEFF
        case .cobalt: 0x5468FF
        case .violet: 0x9466FF
        case .orchid: 0xD861F2
        case .rose: 0xFF4F8E
        case .slate: 0x8C95A8
        }
    }

    var color: Color { Color(hex: hex) }

    /// A gradient for tiles and flood cards that lightens toward the top, keeping ink readable.
    var gradient: LinearGradient {
        LinearGradient(colors: [color.mix(with: .white, by: 0.16), color], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

extension Font {
    /// Giant compressed numerals and codes: project codes, counts, times.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.compressed)
    }

    /// Wide, tracked labels: "NOW", "NEEDS YOU", section headers.
    static func label(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }

    /// Condensed names: projects, tasks, steps.
    static func headline(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// Paths, branches and commit hashes.
    static func code(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// Digits that roll as they change, like a departure board, or simply change under Reduce Motion.
    func rollingDigits(countsDown: Bool = false) -> some View {
        modifier(RollingDigits(countsDown: countsDown))
    }
}

private struct RollingDigits: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let countsDown: Bool

    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText(countsDown: countsDown))
    }
}

/// An uppercase, tracked label.
struct TrackedLabel: View {
    private let text: Text
    var size: CGFloat
    var color: Color

    init<S: StringProtocol>(_ content: S, size: CGFloat = 12, color: Color = Switchyard.textSecondary) {
        text = Text(content)
        self.size = size
        self.color = color
    }

    var body: some View {
        text
            .textCase(.uppercase)
            .font(.label(size))
            .tracking(size * 0.12)
            .foregroundStyle(color)
            // Tracking widens the text after layout; let it take the room it needs rather than clip.
            .fixedSize(horizontal: false, vertical: true)
    }
}
