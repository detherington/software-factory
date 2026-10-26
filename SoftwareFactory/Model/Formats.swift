import Foundation

/// Display formatting.
nonisolated enum Formats {
    /// "now", "4 m", "2 h", "3 d", "5 w", "4 mo".
    static func ago(_ date: Date, from now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3600: return "\(Int(seconds / 60)) m"
        case ..<86_400: return "\(Int(seconds / 3600)) h"
        case ..<(14 * 86_400): return "\(Int(seconds / 86_400)) d"
        case ..<(60 * 86_400): return "\(Int(seconds / (7 * 86_400))) w"
        default: return "\(Int(seconds / (30 * 86_400))) mo"
        }
    }

    /// "6 h 32 m", "12 m", "40 s".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds))) s" }
        let minutes = Int((seconds / 60).rounded())
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return "\(m) m" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    /// Whether this locale writes times with AM/PM.
    static let uses12Hour: Bool = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false

    /// The clock and the day-period marker apart, for big numerals with a small label: ("5:40", "PM").
    static func clock(_ date: Date) -> (clock: String, meridiem: String?) {
        let formatter = DateFormatter()
        formatter.locale = .current
        guard uses12Hour else {
            formatter.dateFormat = "H:mm"
            return (formatter.string(from: date), nil)
        }
        formatter.dateFormat = "h:mm"
        let clock = formatter.string(from: date)
        formatter.dateFormat = "a"
        return (clock, formatter.string(from: date))
    }

    /// "Today", "Yesterday", "Thu, Oct 22".
    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "42%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
