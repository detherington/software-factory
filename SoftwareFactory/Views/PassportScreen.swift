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
    @Environment(Navigator.self) private var navigator
    @Environment(PassportStore.self) private var passport

    var body: some View {
        let now = store.now
        let summary = passport.summary(period, now: now)
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(label: summary.range, title: String(localized: "Passport")) {
                HStack(spacing: 6) {
                    ForEach(PassportPeriod.allCases) { item in
                        FilterChip(title: item.title, isSelected: item == period) { period = item }
                    }
                }
            }
            if passport.lastRead == nil, passport.ledger.transcripts.isEmpty {
                FirstRead(isReading: passport.isReading)
            } else {
                Text(summary.sentence(for: period))
                    .font(.headline(22, weight: .semibold))
                    .foregroundStyle(Switchyard.textSecondary)
                PassportStats(summary: summary)
                    .padding(.bottom, 4)
                SectionLabel(String(localized: "By day"))
                PassportDays(days: summary.days, now: now)
                if !summary.rows.isEmpty {
                    SectionLabel(String(localized: "Projects"), trailing: "\(summary.rows.count)")
                    ProjectTable(rows: summary.rows)
                }
                if !summary.stamps.isEmpty {
                    SectionLabel(String(localized: "Stamps"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 20)], alignment: .leading, spacing: 20) {
                        ForEach(summary.stamps) { stamp in
                            PassportStamp(stamp: stamp)
                                .onTapGesture { if let project = stamp.project, !project.isEmpty { navigator.open(project) } }
                        }
                    }
                    .padding(.vertical, 6)
                }
                footer(now: now)
            }
        }
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
