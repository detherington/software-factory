import SwiftUI

/// The morning digest as a screen: the days since the last one in numbers, then what's been left
/// (questions, blocks, loose ends, old to-dos), each with what to do about it.
struct TodayScreen: View {
    @Environment(PassportStore.self) private var passport

    var body: some View {
        ScrollView {
            TodayContent()
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .readableWidth()
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .onAppear { passport.readIfStale() }
    }
}

struct TodayContent: View {
    @Environment(ProjectStore.self) private var store
    @Environment(DigestStore.self) private var digests

    var body: some View {
        let now = store.now
        let digest = digests.digest(now: now)
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(label: now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: String(localized: "Today"))
            Text(digest.sentence)
                .font(.headline(22, weight: .semibold))
                .foregroundStyle(Switchyard.textSecondary)
            SectionLabel(digest.period, trailing: digest.range)
            PassportStats(summary: digest.summary)
                .padding(.bottom, 4)

            if !digest.waiting.isEmpty {
                SectionLabel(String(localized: "Waiting on you"), trailing: "\(digest.waiting.count)")
                Card(padding: 20) {
                    ForEach(digest.waiting) { WaitingRow(nudge: $0, now: now) }
                }
            }
            if !digest.looseEnds.isEmpty {
                SectionLabel(String(localized: "Loose ends"), trailing: "\(digest.looseEnds.count)")
                Card(padding: 20) {
                    ForEach(digest.looseEnds) { LooseEndsRow(nudge: $0, now: now) }
                }
            }
            if !digest.todos.isEmpty {
                SectionLabel(String(localized: "Old to-dos"), trailing: "\(digest.todos.reduce(0) { $0 + ($1.todos?.count ?? 0) })")
                Card(padding: 20) {
                    ForEach(digest.todos) { OldTodos(nudge: $0, now: now) }
                }
            }
            if digest.waiting.isEmpty, digest.looseEnds.isEmpty, digest.todos.isEmpty {
                Card(padding: 24) {
                    Text("Nothing's waiting on you, and nothing's been left.")
                        .font(.headline(20, weight: .semibold))
                        .foregroundStyle(Switchyard.text)
                    Text("No questions, no loose ends, no old to-dos.")
                        .foregroundStyle(Switchyard.textSecondary)
                }
            }
            if !digest.summary.rows.isEmpty {
                SectionLabel(String(localized: "Projects"), trailing: "\(digest.summary.rows.count)")
                ProjectTable(rows: digest.summary.rows)
            }
            footer(digest)
        }
    }

    private func footer(_ digest: Digest) -> some View {
        let time = digests.time.formatted(date: .omitted, time: .shortened)
        let days = digests.weekdaysOnly ? String(localized: "on weekdays") : String(localized: "every day")
        let when: String = {
            guard digests.isOn else { return String(localized: "The morning digest is off. Turn it on in Settings › Morning Digest.") }
            if let sent = digest.sent {
                let at = sent.formatted(date: .omitted, time: .shortened)
                if digests.state.record?.toPhone == true { return String(localized: "Today's digest went to your iPhone at \(at): nobody was at a Mac.") }
                if let machine = digests.state.record?.machine, machine != store.machineName {
                    return String(localized: "Today's digest went out at \(at) on \(machine).")
                }
                return String(localized: "Today's digest went out at \(at).")
            }
            return String(localized: "The digest comes at \(time) \(days), once you're at a Mac.")
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(when)
            if !digest.snoozed.isEmpty {
                HStack(spacing: 8) {
                    Text(digest.snoozed.count == 1 ? String(localized: "1 snoozed.") : String(localized: "\(digest.snoozed.count) snoozed."))
                    Button(String(localized: "Wake Them")) { digests.wakeSnoozed() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Switchyard.accent)
                }
            }
            Text("Loose ends show once a project has been quiet for a day, and to-dos once nobody has touched them for a week.")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Switchyard.textTertiary)
        .padding(.top, 16)
    }
}

/// A nudge's line: the project's code on a tile, its name and what's up, how long, and what to do.
private struct NudgeLine<Detail: View, Actions: View>: View {
    let nudge: Nudge
    let swatch: Swatch
    let now: Date
    var age: String?
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions
    @Environment(ProjectStore.self) private var store
    @Environment(Navigator.self) private var navigator
    @Environment(DigestStore.self) private var digests

    var body: some View {
        let project = store[nudge.project]
        HStack(alignment: .center, spacing: 14) {
            CodeTile(code: project?.code ?? "—", swatch: swatch, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(project?.name ?? nudge.project)
                    .font(.headline(17, weight: .semibold))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(1)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { navigator.open(nudge.project) }
            Text(Formats.ago(nudge.since, from: now))
                .font(.display(18, weight: .heavy))
                .foregroundStyle(Switchyard.textTertiary)
                .help(age ?? nudge.since.formatted(date: .abbreviated, time: .shortened))
            actions
                .buttonStyle(.glass)
                .controlSize(.small)
            Menu {
                Button(String(localized: "Snooze for a Day")) { digests.snooze(nudge, days: 1) }
                Button(String(localized: "Snooze for a Week")) { digests.snooze(nudge, days: 7) }
            } label: {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Switchyard.textTertiary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Snooze"))
        }
        .padding(.vertical, 4)
    }
}

/// A question waiting for an answer, or a block.
private struct WaitingRow: View {
    let nudge: Nudge
    let now: Date
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let project = store[nudge.project]
        let session = project?.sessions.first { $0.id == nudge.session }
        let chat = session.flatMap(store.chat(for:)) ?? (nudge.kind == .blocked ? project.flatMap(store.bestChat(for:)) : nil)
        NudgeLine(nudge: nudge, swatch: (nudge.state ?? .waiting).swatch, now: now) {
            let place = nudge.machine.map { String(localized: "On \($0)") }
            let line = [nudge.detail, place].compactMap { $0 }.joined(separator: " · ")
            Text(line.isEmpty ? (nudge.state ?? .waiting).label : line)
                .font(.system(size: 13))
                .foregroundStyle(Switchyard.textSecondary)
                .lineLimit(2)
        } actions: {
            if let chat {
                Button(String(localized: "Open Chat")) { Reveal.chat(chat) }
            }
        }
    }
}

/// Uncommitted or unpushed work in a project that's been quiet.
private struct LooseEndsRow: View {
    let nudge: Nudge
    let now: Date
    @Environment(ProjectStore.self) private var store
    @Environment(PromptStore.self) private var prompts

    var body: some View {
        let project = store[nudge.project]
        let ends = nudge.looseEnds ?? []
        let tidy = prompts.all.first { $0.id == PromptStore.tidyLooseEnds && !$0.deleted }
        // The starter opens a chat in the project's own folder, so only its loose ends are in reach.
        let here = ends.contains { $0.machine == nil && $0.worktree == nil } && project?.isOnThisMac == true
        NudgeLine(nudge: nudge, swatch: .slate, now: now,
                  age: String(localized: "Quiet since \(nudge.since.formatted(date: .abbreviated, time: .shortened))")) {
            HStack(spacing: 6) { LooseEndsChips(ends: ends) }
        } actions: {
            if let tidy, let project, here {
                Button(tidy.title) { prompts.start(tidy, in: project) }
                    .help(tidy.text)
            }
        }
    }
}

/// A project's to-dos that nobody has touched for a week.
private struct OldTodos: View {
    let nudge: Nudge
    let now: Date
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let project = store[nudge.project]
        let todos = nudge.todos ?? []
        VStack(alignment: .leading, spacing: 4) {
            NudgeLine(nudge: nudge, swatch: .slate, now: now,
                      age: String(localized: "Untouched since \(nudge.since.formatted(date: .abbreviated, time: .omitted))")) {
                Text(todos.count == 1 ? String(localized: "1 to-do untouched for a week or more")
                                      : String(localized: "\(todos.count) to-dos untouched for a week or more"))
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textSecondary)
            } actions: {
                EmptyView()
            }
            ForEach(todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { store.changeTodo(todo.id, in: nudge.project, done: true) } label: {
                        Image(systemName: "circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Switchyard.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Done"))
                    Text(todo.text)
                        .font(.headline(16, weight: .medium))
                        .foregroundStyle(Switchyard.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Formats.ago(todo.updated, from: now))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Switchyard.textTertiary)
                    if let project, let path = project.path, project.isOnThisMac {
                        Button { Reveal.newChat(in: path, prompt: todo.text) } label: {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Switchyard.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Start in Claude"))
                    }
                }
                .padding(.leading, 54)
                .contextMenu {
                    if let project, let path = project.path, project.isOnThisMac {
                        Button("Start in Claude", systemImage: "bubble.left.and.text.bubble.right") { Reveal.newChat(in: path, prompt: todo.text) }
                    }
                    Button("Done", systemImage: "checkmark") { store.changeTodo(todo.id, in: nudge.project, done: true) }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { store.deleteTodo(todo.id, in: nudge.project) }
                }
            }
        }
        .padding(.bottom, 6)
    }
}
