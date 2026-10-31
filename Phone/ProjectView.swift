import SwiftUI

/// One project: what's happening now, its progress, sessions, to-dos and timeline.
struct ProjectView: View {
    let id: String
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let now = board.now
        ScrollView {
            if let project = board[id] {
                content(project, now: now)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
            } else {
                Text("This project isn't on the board anymore.")
                    .foregroundStyle(Switchyard.textSecondary)
                    .padding(40)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await board.refresh() }
        .background(Switchyard.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ project: Project, now: Date) -> some View {
        let state = project.state(at: now)
        let steps = project.displaySteps(at: now)
        let live = project.liveSessions(at: now)
        return VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(label: [project.code, project.branch].compactMap { $0 }.joined(separator: " · "), title: project.name)
            Now(project: project, now: now)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    StateChip(state: state, mode: project.mode(at: now), since: Formats.ago(project.stateSince(at: now), from: now))
                    LooseEndsChips(ends: project.openLooseEnds)
                    if let status = project.appStore { AppStoreChips(status: status, now: now) }
                    if let version = project.version { CodeChip(text: version, symbol: "tag.fill") }
                }
            }
            .scrollIndicators(.hidden)

            if let fraction = project.fraction(at: now) {
                Card(padding: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Formats.percent(fraction))
                            .font(.display(48, weight: .heavy))
                            .foregroundStyle(state.swatch == .slate ? Switchyard.text : state.swatch.color)
                        TrackedLabel(project.milestone ?? String(localized: "Progress"), size: 11, color: Switchyard.textTertiary)
                    }
                    if steps.isEmpty {
                        Strip.fraction(fraction, color: state.swatch.color, track: Switchyard.surfaceRaised)
                    }
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: step.status == .done ? "checkmark.circle.fill" : step.status == .active ? "circle.dotted.circle" : "circle")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(step.status == .todo ? Switchyard.textTertiary : Switchyard.text)
                                .frame(width: 18)
                            Text(step.title)
                                .font(.headline(16, weight: step.status == .active ? .bold : .medium))
                                .foregroundStyle(step.status == .done ? Switchyard.textSecondary : Switchyard.text)
                                .strikethrough(step.status == .done, color: Switchyard.textTertiary)
                        }
                    }
                }
            }

            if live.count > 1 || live.contains(where: { $0.machine != nil || $0.worktree != nil }) {
                SectionLabel(String(localized: "Sessions"), trailing: "\(live.count)")
                Card(padding: 16) {
                    ForEach(live) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            StateChip(state: session.state, mode: session.mode, since: Formats.ago(session.since, from: now))
                            if let line = session.ask ?? session.message ?? session.task {
                                Text(line).font(.headline(16, weight: .medium)).foregroundStyle(Switchyard.text)
                            }
                            // "On Ratatoskr · In clever-elbakyan · claude/clever-elbakyan"
                            let place = [session.machine.map { String(localized: "On \($0)") },
                                         session.worktree.map { String(localized: "In \($0)") },
                                         session.worktree == nil ? nil : project.checkout(for: session)?.branch].compactMap { $0 }
                            if !place.isEmpty {
                                Text(place.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Switchyard.textTertiary)
                            }
                            AnswerLink(session: session)
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            let todos = project.openTodos
            SectionLabel(String(localized: "To do"), trailing: todos.isEmpty ? nil : "\(todos.count)")
            TodoList(project: project, todos: todos)

            if !project.events.isEmpty {
                SectionLabel(String(localized: "Timeline"))
                Card(padding: 16) {
                    ForEach(project.events.prefix(20)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: event.symbol ?? "circle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(event.state?.swatch.color ?? Switchyard.textTertiary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title)
                                    .font(.headline(15, weight: .medium))
                                    .foregroundStyle(Switchyard.text)
                                    .lineLimit(2)
                                if let detail = [event.detail, event.machine.map { String(localized: "on \($0)") }].compactMap({ $0 }).first {
                                    Text(detail).font(.system(size: 12)).foregroundStyle(Switchyard.textTertiary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Formats.ago(event.date, from: now))
                                .font(.display(15, weight: .bold))
                                .foregroundStyle(Switchyard.textTertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            if let summary = project.displaySummary {
                SectionLabel(String(localized: "About"))
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Switchyard.textSecondary)
            }
        }
    }
}

/// Your to-dos for a project: add one, tick one off, or delete one (press and hold). Your Macs pick
/// up the change within moments.
private struct TodoList: View {
    let project: Project
    let todos: [Todo]
    @Environment(PhoneBoard.self) private var board
    @State private var draft = ""
    @FocusState private var adding: Bool

    var body: some View {
        Card(padding: 16) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Switchyard.accent)
                TextField(String(localized: "Add something to tackle…"), text: $draft)
                    .font(.headline(16, weight: .medium))
                    .foregroundStyle(Switchyard.text)
                    .focused($adding)
                    .submitLabel(.done)
                    .onSubmit(add)
            }
            .padding(.vertical, 4)
            ForEach(todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { board.setTodo(todo, done: true, in: project) } label: {
                        Image(systemName: "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Switchyard.textTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Done"))
                    Text(todo.text)
                        .font(.headline(16, weight: .medium))
                        .foregroundStyle(Switchyard.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Done", systemImage: "checkmark") { board.setTodo(todo, done: true, in: project) }
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = todo.text }
                    Button("Delete", systemImage: "trash", role: .destructive) { board.deleteTodo(todo, in: project) }
                }
            }
        }
    }

    private func add() {
        board.addTodo(draft, to: project)
        draft = ""
    }
}

/// What's happening now: how long it's been waiting or working, in its state's color, or what was
/// last worked on.
private struct Now: View {
    let project: Project
    let now: Date
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let state = project.state(at: now)
        if state.isLive {
            VStack(alignment: .leading, spacing: 6) {
                TrackedLabel(label(state), size: 11, color: Switchyard.ink.opacity(0.72))
                Text(elapsed(now.timeIntervalSince(project.stateSince(at: now))))
                    .font(.display(72, weight: .black))
                    .foregroundStyle(Switchyard.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let headline = project.headline(at: now) {
                    Text(headline)
                        .font(.headline(20, weight: .semibold))
                        .foregroundStyle(Switchyard.ink)
                }
                if let activity = project.leadSession(at: now)?.activity, state == .working {
                    Label(activity, systemImage: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Switchyard.ink.opacity(0.8))
                }
                if let ask = project.openPermission(at: now)?.ask {
                    PermissionPrompt(ask: ask, onFlood: true, sent: board.answeredPermissions[ask.id]) { reply in
                        board.answer(ask, reply: reply, in: project)
                    }
                    .padding(.top, 8)
                    if let session = project.openable(at: now) {
                        AnswerLink(session: session, onFlood: true)
                    }
                } else if let session = project.openReply(at: now) {
                    ReplyPrompt(session: session, onFlood: true, sent: board.hasReplied(to: session)) { text in
                        board.reply(to: session, text: text, in: project)
                    }
                    .padding(.top, 8)
                    if let session = project.openable(at: now) {
                        AnswerLink(session: session, onFlood: true)
                    }
                } else if let session = project.openable(at: now) {
                    AnswerLink(session: session, onFlood: true)
                        .padding(.top, 8)
                } else if state.asksYou {
                    Text("To answer from here, turn on Remote Control for its chat in Claude on your Mac.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Switchyard.ink.opacity(0.72))
                        .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.swatch.gradient, in: .rect(cornerRadius: Switchyard.cardRadius, style: .continuous))
        } else if let line = state == .done ? (project.note ?? project.task) : (project.task ?? project.note) {
            Card(padding: 18) {
                TrackedLabel(state == .done ? String(localized: "Shipped") : String(localized: "Last worked on"), size: 11, color: Switchyard.textTertiary)
                Text(line)
                    .font(.headline(22, weight: .bold))
                    .foregroundStyle(Switchyard.text)
                Text(project.lastActivity.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textTertiary)
            }
        }
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(localized: "Now") : Formats.duration(seconds)
    }

    private func label(_ state: ProjectState) -> String {
        switch state {
        case .waiting: String(localized: "Waiting for you for")
        case .blocked: String(localized: "Blocked for")
        case .background: String(localized: "In the background for")
        case .yourCall: String(localized: "Your call for")
        default: String(localized: "Working for")
        }
    }
}
