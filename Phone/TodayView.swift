import SwiftUI

/// Today, as on the Mac: the days since the last digest in numbers, then what's been left, each to
/// snooze or act on. A Mac makes the digest and sends it with the board.
struct TodayView: View {
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let now = board.now
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(label: now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: String(localized: "Today"))
                if let digest = board.digest {
                    content(digest, now: now)
                } else {
                    Card(padding: 20) {
                        Text("Today comes from your Macs.")
                            .font(.headline(20, weight: .semibold))
                            .foregroundStyle(Switchyard.text)
                        Text("Software Factory on a Mac signed in to the same iCloud account sends it with the board.")
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
    private func content(_ digest: Digest, now: Date) -> some View {
        Text(digest.sentence)
            .font(.headline(20, weight: .semibold))
            .foregroundStyle(Switchyard.textSecondary)
        SectionLabel(digest.period, trailing: digest.range)
        Numbers(summary: digest.summary)
            .padding(.bottom, 4)

        if !digest.waiting.isEmpty {
            SectionLabel(String(localized: "Waiting on you"), trailing: "\(digest.waiting.count)")
            Card(padding: 16) {
                ForEach(digest.waiting) { nudge in
                    let answer = board[nudge.project]?.sessions.first { $0.id == nudge.session }?.claudeURL
                    NudgeRow(nudge: nudge, swatch: (nudge.state ?? .waiting).swatch, now: now, answer: answer) {
                        let place = nudge.machine.map { String(localized: "On \($0)") }
                        let line = [nudge.detail, place].compactMap { $0 }.joined(separator: " · ")
                        Text(line.isEmpty ? (nudge.state ?? .waiting).label : line)
                            .font(.system(size: 13))
                            .foregroundStyle(Switchyard.textSecondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        if !digest.looseEnds.isEmpty {
            SectionLabel(String(localized: "Loose ends"), trailing: "\(digest.looseEnds.count)")
            Card(padding: 16) {
                ForEach(digest.looseEnds) { nudge in
                    NudgeRow(nudge: nudge, swatch: .slate, now: now) {
                        FlowChips { LooseEndsChips(ends: nudge.looseEnds ?? []) }
                    }
                }
            }
        }
        if !digest.todos.isEmpty {
            SectionLabel(String(localized: "Old to-dos"), trailing: "\(digest.todos.reduce(0) { $0 + ($1.todos?.count ?? 0) })")
            Card(padding: 16) {
                ForEach(digest.todos) { OldTodos(nudge: $0, now: now) }
            }
        }
        if digest.waiting.isEmpty, digest.looseEnds.isEmpty, digest.todos.isEmpty {
            Card(padding: 20) {
                Text("Nothing's waiting on you, and nothing's been left.")
                    .font(.headline(18, weight: .semibold))
                    .foregroundStyle(Switchyard.text)
            }
        }
        let rows = digest.summary.rows.filter { !$0.id.isEmpty }
        if !rows.isEmpty {
            SectionLabel(String(localized: "Projects"), trailing: "\(rows.count)")
            Card(padding: 16) {
                ForEach(rows) { row in
                    NavigationLink(value: row.id) { ProjectRow(row: row) }
                        .buttonStyle(.plain)
                }
            }
        }
        Group {
            if !digest.snoozed.isEmpty {
                Text(digest.snoozed.count == 1 ? String(localized: "1 snoozed.") : String(localized: "\(digest.snoozed.count) snoozed."))
            }
            Text("Loose ends show once a project has been quiet for a day, and to-dos once nobody has touched them for a week.")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Switchyard.textTertiary)
        .padding(.top, 6)
    }
}

/// The period's numbers, three to a row.
private struct Numbers: View {
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

/// A nudge: the project's code on a tile, its name and what's up, how long, a way to answer it in the
/// Claude app, and a snooze.
private struct NudgeRow<Detail: View>: View {
    let nudge: Nudge
    let swatch: Swatch
    let now: Date
    var answer: URL? = nil
    @ViewBuilder var detail: Detail
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let project = board[nudge.project]
        HStack(alignment: .center, spacing: 12) {
            NavigationLink(value: nudge.project) {
                HStack(alignment: .center, spacing: 12) {
                    CodeTile(code: project?.code ?? "—", swatch: swatch, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project?.name ?? nudge.project)
                            .font(.headline(16, weight: .semibold))
                            .foregroundStyle(Switchyard.text)
                            .lineLimit(1)
                        detail
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Formats.ago(nudge.since, from: now))
                        .font(.display(16, weight: .heavy))
                        .foregroundStyle(Switchyard.textTertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let answer {
                Link(destination: answer) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Switchyard.accent)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel(String(localized: "Answer in Claude"))
            }
            SnoozeMenu(nudge: nudge)
        }
        .padding(.vertical, 4)
    }
}

private struct SnoozeMenu: View {
    let nudge: Nudge
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        Menu {
            Button(String(localized: "Snooze for a Day"), systemImage: "moon.zzz") { board.snooze(nudge, days: 1) }
            Button(String(localized: "Snooze for a Week"), systemImage: "moon.zzz.fill") { board.snooze(nudge, days: 7) }
        } label: {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Switchyard.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .accessibilityLabel(String(localized: "Snooze"))
    }
}

/// A project's to-dos that nobody has touched for a week: tick one off, or snooze them all.
private struct OldTodos: View {
    let nudge: Nudge
    let now: Date
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let project = board[nudge.project]
        let todos = nudge.todos ?? []
        VStack(alignment: .leading, spacing: 6) {
            NudgeRow(nudge: nudge, swatch: .slate, now: now) {
                Text(todos.count == 1 ? String(localized: "1 to-do untouched for a week or more")
                                      : String(localized: "\(todos.count) to-dos untouched for a week or more"))
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textSecondary)
            }
            ForEach(todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { if let project { board.setTodo(todo, done: true, in: project) } } label: {
                        Image(systemName: "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Switchyard.textTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Done"))
                    Text(todo.text)
                        .font(.headline(15, weight: .medium))
                        .foregroundStyle(Switchyard.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Formats.ago(todo.updated, from: now))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Switchyard.textTertiary)
                }
                .padding(.leading, 48)
                .contextMenu {
                    if let project {
                        Button("Done", systemImage: "checkmark") { board.setTodo(todo, done: true, in: project) }
                        Button("Delete", systemImage: "trash", role: .destructive) { board.deleteTodo(todo, in: project) }
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }
}

/// A project's numbers for the period: "TDR  Tachyon Drifter  9.6 h · 14 commits".
private struct ProjectRow: View {
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
