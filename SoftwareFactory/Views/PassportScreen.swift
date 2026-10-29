import SwiftUI

/// Your week in numbers, like Sojourny's Passport: Claude's working hours, sessions, commits, builds,
/// releases and tokens, by day and by project, with stamps for the milestones.
struct PassportScreen: View {
    @State private var period = PassportPeriod.thisWeek
    @Environment(PassportStore.self) private var passport

    var body: some View {
        ScrollView {
            PassportContent(period: $period)
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .readableWidth()
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .onAppear { passport.readIfStale() }
    }
}

struct PassportContent: View {
    @Binding var period: PassportPeriod
    @Environment(ProjectStore.self) private var store
    @Environment(PassportStore.self) private var passport

    var body: some View {
        let now = store.now
        let summary = passport.summary(period, now: now)
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(label: range(summary), title: String(localized: "Passport")) {
                HStack(spacing: 6) {
                    ForEach(PassportPeriod.allCases) { item in
                        FilterChip(title: item.title, isSelected: item == period) { period = item }
                    }
                }
            }
            if passport.lastRead == nil, passport.ledger.transcripts.isEmpty {
                FirstRead(isReading: passport.isReading)
            } else {
                Text(sentence(summary))
                    .font(.headline(22, weight: .semibold))
                    .foregroundStyle(Switchyard.textSecondary)
                PassportStats(summary: summary)
                    .padding(.bottom, 4)
                SectionLabel(String(localized: "By day"))
                DayStrip(days: summary.days, now: now)
                if !summary.rows.isEmpty {
                    SectionLabel(String(localized: "Projects"), trailing: "\(summary.rows.count)")
                    ProjectTable(rows: summary.rows)
                }
                if !summary.stamps.isEmpty {
                    SectionLabel(String(localized: "Stamps"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 20)], alignment: .leading, spacing: 20) {
                        ForEach(summary.stamps) { StampView(stamp: $0) }
                    }
                    .padding(.vertical, 6)
                }
                footer(now: now)
            }
        }
    }

    /// "Oct 25 – 31".
    private func range(_ summary: PassportSummary) -> String {
        guard let first = summary.days.first?.date, let last = summary.days.last?.date else { return "" }
        let style = Date.FormatStyle().month(.abbreviated).day()
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }

    /// "31 hours of Claude's work across 9 projects. Last week came to 45."
    private func sentence(_ summary: PassportSummary) -> String {
        let projects = summary.rows.filter { !$0.id.isEmpty && $0.usage.seconds >= 60 }.count
        let hours = Formats.hours(summary.total.seconds)
        guard summary.total.seconds >= 60 else {
            switch period {
            case .thisWeek:
                guard let previous = summary.previousSeconds else { return String(localized: "No Claude Code work yet this week.") }
                return String(localized: "No Claude Code work yet this week. Last week came to \(Formats.hours(previous)) hours.")
            case .lastWeek: return String(localized: "No Claude Code work last week.")
            case .month: return String(localized: "No Claude Code work in the last 30 days.")
            }
        }
        let work = projects == 1
            ? String(localized: "\(hours) hours of Claude's work, on one project.")
            : String(localized: "\(hours) hours of Claude's work across \(projects) projects.")
        // Nothing to compare with when the transcripts from before were gone before the board read them.
        guard let previous = summary.previousSeconds else { return work }
        if period == .thisWeek { return work + " " + String(localized: "Last week came to \(Formats.hours(previous)).") }
        let difference = Formats.hours(abs(summary.total.seconds - previous))
        let before = period == .lastWeek ? String(localized: "the week before") : String(localized: "the 30 days before")
        if difference == "0" { return work + " " + String(localized: "The same as \(before).") }
        return work + " " + (summary.total.seconds > previous
            ? String(localized: "\(difference) more than \(before).")
            : String(localized: "\(difference) fewer than \(before)."))
    }

    private func footer(now: Date) -> some View {
        let macs = passport.otherMacs.isEmpty
            ? String(localized: "This Mac")
            : String(localized: "This Mac and \(passport.otherMacs.formatted(.list(type: .and)))")
        let read = passport.isReading ? String(localized: "reading…") : passport.lastRead.map { String(localized: "read \(Formats.ago($0, from: now))") } ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(macs) · \(read)")
            Text("Hours are the time Claude spent on your turns, from your message to its last reply. Waiting for you doesn't count, and no single step counts for more than 30 minutes. Tokens include those read from the cache.")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Switchyard.textTertiary)
        .padding(.top, 16)
    }
}

/// The first read of every transcript, which takes a moment.
private struct FirstRead: View {
    let isReading: Bool

    var body: some View {
        Card(padding: 24) {
            HStack(spacing: 12) {
                if isReading { ProgressView().controlSize(.small) }
                Text(isReading ? "Reading your Claude Code transcripts…" : "Your numbers appear after the first read of your transcripts.")
                    .font(.headline(20, weight: .semibold))
                    .foregroundStyle(Switchyard.text)
            }
            Text("The first time takes a few seconds for each gigabyte. After that, only what's new is read.")
                .foregroundStyle(Switchyard.textSecondary)
        }
    }
}

/// Giant numerals over tracked labels, as on the board.
struct PassportStats: View {
    let summary: PassportSummary

    var body: some View {
        let total = summary.total
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 28, alignment: .leading)], alignment: .leading, spacing: 12) {
            stat(Formats.hours(total.seconds), "Hours", total.seconds >= 60 ? .violet : nil)
                .help(String(localized: "\(total.turns) turns"))
            stat("\(summary.sessions)", "Sessions", nil, zero: summary.sessions == 0)
            stat("\(summary.commits)", "Commits", nil, zero: summary.commits == 0)
            stat("\(summary.builds)", "Builds", summary.builds > 0 ? .sky : nil, zero: summary.builds == 0)
                .help(String(localized: "TestFlight builds uploaded"))
            stat("\(summary.releases.count)", "Shipped", summary.releases.isEmpty ? nil : .mint, zero: summary.releases.isEmpty)
            stat(Formats.tokens(total.tokens), "Tokens", nil, zero: total.tokens == 0)
                .help(String(localized: "\(Formats.tokens(total.output)) written; \(Formats.tokens(total.input + total.cacheWrite)) read fresh and \(Formats.tokens(total.cacheRead)) from the cache"))
        }
    }

    private func stat(_ value: String, _ label: String, _ swatch: Swatch?, zero: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.display(64, weight: .heavy))
                .foregroundStyle(zero || value == "0" ? Switchyard.textTertiary : swatch?.color ?? Switchyard.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            TrackedLabel(label, size: 11, color: Switchyard.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Each day's hours as a bar, with marks for builds and releases.
private struct DayStrip: View {
    let days: [PassportSummary.Day]
    let now: Date

    var body: some View {
        let most = max(days.map(\.usage.seconds).max() ?? 0, 3600)
        let wide = days.count <= 7
        let today = Calendar.current.startOfDay(for: now)
        Card(padding: 20) {
            HStack(alignment: .bottom, spacing: wide ? 14 : 4) {
                ForEach(days) { day in
                    let isToday = day.date == today
                    VStack(spacing: 6) {
                        if wide {
                            Text(day.usage.seconds >= 60 ? Formats.hours(day.usage.seconds) : " ")
                                .font(.display(20, weight: .bold))
                                .foregroundStyle(isToday ? Switchyard.text : Switchyard.textSecondary)
                        }
                        bar(day, fraction: day.usage.seconds / most, isToday: isToday)
                        HStack(spacing: 3) {
                            if day.releases > 0 { mark("checkmark", .mint) }
                            if day.builds > 0 { mark("paperplane.fill", .sky) }
                        }
                        .frame(height: 12)
                        if wide {
                            TrackedLabel(day.date.formatted(.dateTime.weekday(.abbreviated)), size: 10,
                                         color: isToday ? Switchyard.text : Switchyard.textTertiary)
                        }
                        Text(day.date.formatted(.dateTime.day()))
                            .font(.display(wide ? 22 : 14, weight: .heavy))
                            .foregroundStyle(isToday ? Switchyard.text : Switchyard.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(tooltip(day))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tooltip(day))
                }
            }
        }
    }

    private func bar(_ day: PassportSummary.Day, fraction: Double, isToday: Bool) -> some View {
        let height: CGFloat = 140
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Switchyard.surfaceRaised)
            if day.usage.seconds > 0 {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Swatch.violet.color.opacity(isToday || day.isFuture ? 1 : 0.85))
                    .frame(height: max(4, height * fraction))
            }
        }
        .frame(height: height)
        .opacity(day.isFuture ? 0.4 : 1)
    }

    private func mark(_ symbol: String, _ swatch: Swatch) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(swatch.color)
    }

    private func tooltip(_ day: PassportSummary.Day) -> String {
        var parts = [day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                     String(localized: "\(Formats.hours(day.usage.seconds)) hours")]
        if day.usage.turns > 0 { parts.append(String(localized: "\(day.usage.turns) turns")) }
        if day.commits > 0 { parts.append(String(localized: "\(day.commits) commits")) }
        if day.builds > 0 { parts.append(String(localized: "\(day.builds) builds")) }
        if day.releases > 0 { parts.append(String(localized: "\(day.releases) shipped")) }
        return parts.joined(separator: " · ")
    }
}

/// Each project's share of the period, busiest first.
struct ProjectTable: View {
    let rows: [PassportSummary.Row]
    @Environment(ProjectStore.self) private var store
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let most = max(rows.map(\.usage.seconds).max() ?? 0, 1)
        Card(padding: 20) {
            HStack(spacing: 12) {
                TrackedLabel(String(localized: "Project"), size: 10, color: Switchyard.textTertiary)
                Spacer()
                ForEach(Self.columns, id: \.self) { column in
                    TrackedLabel(column, size: 10, color: Switchyard.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: Self.columnWidth, alignment: .trailing)
                }
            }
            ForEach(rows) { row in
                Button { if !row.id.isEmpty { navigator.open(row.id) } } label: {
                    line(row, fraction: row.usage.seconds / most)
                }
                .buttonStyle(.plain)
                .disabled(row.id.isEmpty)
            }
        }
    }

    private static let columnWidth: CGFloat = 78
    private static let columns = [String(localized: "Hours"), String(localized: "Sessions"), String(localized: "Commits"),
                                  String(localized: "Builds"), String(localized: "Tokens")]

    private func line(_ row: PassportSummary.Row, fraction: Double) -> some View {
        let project = store[row.id]
        return HStack(spacing: 12) {
            Text(project?.code ?? "—")
                .font(.display(24, weight: .heavy))
                .foregroundStyle(Switchyard.text)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(project?.name ?? String(localized: "Other folders"))
                        .font(.headline(16, weight: .semibold))
                        .foregroundStyle(Switchyard.textSecondary)
                        .lineLimit(1)
                    if row.releases > 0 {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Swatch.mint.color)
                            .help(String(localized: "Shipped \(row.releases)×"))
                    }
                }
                Strip.fraction(fraction, color: Swatch.violet.color, track: Switchyard.surfaceRaised, height: 6)
            }
            number(Formats.hours(row.usage.seconds), zero: row.usage.seconds < 60)
            number("\(row.sessions)", zero: row.sessions == 0)
            number("\(row.commits)", zero: row.commits == 0)
            number("\(row.builds)", zero: row.builds == 0)
            number(row.usage.tokens > 0 ? Formats.tokens(row.usage.tokens) : "0", zero: row.usage.tokens == 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func number(_ text: String, zero: Bool) -> some View {
        Text(text)
            .font(.display(22, weight: .bold))
            .foregroundStyle(zero ? Switchyard.textTertiary.opacity(0.6) : Switchyard.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: Self.columnWidth, alignment: .trailing)
    }
}

/// A milestone, inked like a passport stamp: a double border in its color, set at a slight angle.
private struct StampView: View {
    let stamp: PassportSummary.Stamp
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let color = stamp.swatch.color
        VStack(spacing: 4) {
            TrackedLabel(stamp.label, size: 10, color: color)
            Text(stamp.value)
                .font(.display(40, weight: .black))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            TrackedLabel(stamp.caption, size: 9, color: color.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 124)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.9), lineWidth: 2.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(color.opacity(0.45), lineWidth: 1).padding(6)
        }
        .rotationEffect(.degrees(tilt))
        .contentShape(.rect)
        .onTapGesture { if let project = stamp.project, !project.isEmpty { navigator.open(project) } }
        .help(stamp.detail ?? "")
        .accessibilityElement(children: .combine)
    }

    /// Between -4° and 4°, the same each time for the same stamp.
    private var tilt: Double {
        let sum = stamp.id.utf8.reduce(0) { $0 &+ Int($1) }
        return Double(sum % 9) - 4
    }
}
