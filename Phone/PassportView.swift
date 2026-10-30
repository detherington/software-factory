import SwiftUI

/// Your week in numbers, as on the Mac: Claude's hours, sessions, commits, builds, releases and
/// tokens, by day and by project, with stamps for the milestones. A Mac adds them up and sends
/// them with the board.
struct PassportView: View {
    @Environment(PhoneBoard.self) private var board
    @State private var period = PassportPeriod.thisWeek

    var body: some View {
        let now = board.now
        let summary = board.passport?[period]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(label: summary?.range ?? " ", title: String(localized: "Passport"))
                if let passport = board.passport, let summary {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(PassportPeriod.allCases) { item in
                                FilterChip(title: item.title, isSelected: item == period) { period = item }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    content(summary, passport: passport, now: now)
                } else {
                    Card(padding: 20) {
                        Text("The Passport comes from your Macs.")
                            .font(.headline(20, weight: .semibold))
                            .foregroundStyle(Switchyard.text)
                        Text("Software Factory on a Mac signed in to the same iCloud account sends it with the board, once it has read its Claude Code transcripts.")
                            .foregroundStyle(Switchyard.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .refreshable { await board.refresh() }
        .background(Switchyard.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func content(_ summary: PassportSummary, passport: CloudBoard.Passport, now: Date) -> some View {
        Text(summary.sentence(for: period))
            .font(.headline(20, weight: .semibold))
            .foregroundStyle(Switchyard.textSecondary)
        PassportNumbers(summary: summary)
            .padding(.bottom, 4)
        SectionLabel(String(localized: "By day"))
        PassportDays(days: summary.days, now: now, compact: true)
        let rows = summary.rows.filter { !$0.id.isEmpty }
        if !rows.isEmpty {
            SectionLabel(String(localized: "Projects"), trailing: "\(rows.count)")
            Card(padding: 16) {
                ForEach(rows) { row in
                    NavigationLink(value: row.id) { PassportProjectRow(row: row) }
                        .buttonStyle(.plain)
                }
            }
        }
        if !summary.stamps.isEmpty {
            SectionLabel(String(localized: "Stamps"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(summary.stamps) { stamp in
                    if let project = stamp.project, !project.isEmpty {
                        NavigationLink(value: project) { PassportStamp(stamp: stamp) }
                            .buttonStyle(.plain)
                    } else {
                        PassportStamp(stamp: stamp)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        Group {
            let macs = passport.macs.formatted(.list(type: .and))
            if let read = passport.read {
                Text("From \(macs), read \(Formats.ago(read, from: now)) ago.")
            } else {
                Text("From \(macs).")
            }
            Text("Hours are the time Claude spent on your turns, from your message to its last reply. Waiting for you doesn't count, and no single step counts for more than 30 minutes.")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Switchyard.textTertiary)
        .padding(.top, 6)
    }
}

/// A period's numbers, three to a row: on Today and the Passport.
struct PassportNumbers: View {
    let summary: PassportSummary

    var body: some View {
        let total = summary.total
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
            stat(Formats.hours(total.seconds), String(localized: "Hours"), total.seconds >= 60 ? .violet : nil)
            stat("\(summary.sessions)", String(localized: "Sessions"), nil)
            stat("\(summary.commits)", String(localized: "Commits"), nil)
            stat("\(summary.builds)", String(localized: "Builds"), summary.builds > 0 ? .sky : nil)
            stat("\(summary.releases.count)", String(localized: "Shipped"), summary.releases.isEmpty ? nil : .mint)
            stat(Formats.tokens(total.tokens), String(localized: "Tokens"), nil)
        }
    }

    private func stat(_ value: String, _ label: String, _ swatch: Swatch?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.display(44, weight: .heavy))
                .foregroundStyle(value == "0" ? Switchyard.textTertiary : swatch?.color ?? Switchyard.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            TrackedLabel(label, size: 10, color: Switchyard.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A project's numbers for the period: "TDR  Tachyon Drifter  9.6 h · 14 commits".
struct PassportProjectRow: View {
    let row: PassportSummary.Row
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let project = board[row.id]
        let parts = [row.usage.seconds >= 60 ? String(localized: "\(Formats.hours(row.usage.seconds)) h") : nil,
                     row.commits > 0 ? String(localized: "\(row.commits) commits") : nil,
                     row.builds > 0 ? String(localized: "\(row.builds) builds") : nil].compactMap { $0 }
        HStack(spacing: 12) {
            Text(project?.code ?? "—")
                .font(.display(20, weight: .heavy))
                .foregroundStyle(Switchyard.text)
                .frame(width: 46, alignment: .leading)
            Text(project?.name ?? row.id)
                .font(.headline(16, weight: .semibold))
                .foregroundStyle(Switchyard.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if row.releases > 0 {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Swatch.mint.color)
            }
            Text(parts.joined(separator: " · "))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Switchyard.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
