import SwiftUI

struct PhoneRoot: View {
    @Environment(PhoneBoard.self) private var board
    @State private var tab = Tab.board
    @State private var boardPath: [String] = []
    @State private var todayPath: [String] = []
    @State private var passportPath: [String] = []

    enum Tab { case board, today, passport }

    var body: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FactoryWidgetGallery") { WidgetGallery() } else { tabs }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Board", systemImage: "square.grid.2x2.fill", value: Tab.board) {
                NavigationStack(path: $boardPath) {
                    BoardView()
                        .navigationDestination(for: String.self) { ProjectView(id: $0) }
                }
            }
            .badge(board.count(.waiting) + board.count(.yourCall))
            SwiftUI.Tab("Today", systemImage: "sun.horizon.fill", value: Tab.today) {
                NavigationStack(path: $todayPath) {
                    TodayView()
                        .navigationDestination(for: String.self) { ProjectView(id: $0) }
                }
            }
            SwiftUI.Tab("Passport", systemImage: "book.closed.fill", value: Tab.passport) {
                NavigationStack(path: $passportPath) {
                    PassportView()
                        .navigationDestination(for: String.self) { ProjectView(id: $0) }
                }
            }
        }
        // A widget's project, or an alert's; the digest's opens Today.
        .onChange(of: board.opened, initial: true) { _, id in
            guard let id else { return }
            if id == "today" {
                tab = .today
            } else if id == "passport" {
                tab = .passport
            } else {
                tab = .board
                boardPath = [id]
            }
            board.opened = nil
        }
    }
}

/// What needs you, what's under way, and every other project, as on the Mac.
struct BoardView: View {
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let now = board.now
        let live = board.live
        let resting = board.resting
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(label: now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: title)
                Counts()
                    .padding(.bottom, 4)
                if let problem = board.problem {
                    Card(padding: 18) {
                        Text(problem)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Switchyard.textSecondary)
                    }
                }
                if !live.isEmpty {
                    SectionLabel(String(localized: "Now"))
                    ForEach(live) { LiveTile(project: $0, now: now) }
                }
                if !resting.isEmpty {
                    SectionLabel(String(localized: "Projects"), trailing: "\(resting.count)")
                    Card(padding: 16) {
                        ForEach(resting) { project in
                            NavigationLink(value: project.id) { ProjectRow(project: project, now: now) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if board.projects.isEmpty, board.problem == nil {
                    Card(padding: 20) {
                        Text(board.isRefreshing ? "Fetching your board…" : "No projects yet.")
                            .font(.headline(20, weight: .semibold))
                            .foregroundStyle(Switchyard.text)
                        Text("Your Macs send the board here once Settings › iPhone is on in Software Factory.")
                            .foregroundStyle(Switchyard.textSecondary)
                    }
                }
                footer(now: now)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .refreshable { await board.refresh() }
        .background(Switchyard.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var title: String {
        if board.count(.waiting) + board.count(.yourCall) > 0 { return String(localized: "Your move") }
        if board.count(.working) > 0 { return String(localized: "Hard at work") }
        if board.count(.background) > 0 { return String(localized: "Ticking over") }
        if board.count(.blocked) > 0 { return String(localized: "Stuck") }
        return String(localized: "All quiet")
    }

    private func footer(now: Date) -> some View {
        Group {
            if let fetched = board.fetched {
                Text("Updated \(Formats.ago(fetched, from: now)) ago. Pull to refresh.")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Switchyard.textTertiary)
        .padding(.top, 8)
    }
}

/// Counts, Passport style.
private struct Counts: View {
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
            stat(board.count(.waiting), String(localized: "Needs you"), .amber)
            stat(board.count(.yourCall), String(localized: "Your call"), .tangerine)
            stat(board.count(.working), String(localized: "Working"), .violet)
            stat(board.count(.background), String(localized: "Background"), .sky)
            stat(board.count(.blocked), String(localized: "Blocked"), .ember)
            stat(board.board.count, String(localized: "Projects"), nil)
        }
    }

    private func stat(_ value: Int, _ label: String, _ swatch: Swatch?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.display(48, weight: .heavy))
                .foregroundStyle(value == 0 ? Switchyard.textTertiary : swatch?.color ?? Switchyard.text)
                .rollingDigits()
            TrackedLabel(label, size: 10, color: Switchyard.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A live project as a flood of its state's color, with a way to answer it in the Claude app when
/// it's asking you something.
private struct LiveTile: View {
    let project: Project
    let now: Date
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let state = project.state(at: now)
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: project.id) { content(state) }
                .buttonStyle(.plain)
            if let ask = project.openPermission(at: now)?.ask {
                PermissionPrompt(ask: ask, onFlood: true, sent: board.answeredPermissions[ask.id], compact: true) { reply in
                    board.answer(ask, reply: reply, in: project)
                }
            } else if let session = project.openReply(at: now), session.askOptions != nil {
                ReplyPrompt(session: session, onFlood: true, sent: board.hasReplied(to: session), compact: true) { text in
                    board.reply(to: session, text: text, in: project)
                }
            } else if let session = project.answerable(at: now) {
                AnswerLink(session: session, onFlood: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(state.swatch.gradient, in: .rect(cornerRadius: Switchyard.cardRadius, style: .continuous))
    }

    private func content(_ state: ProjectState) -> some View {
        let steps = project.displaySteps(at: now)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TrackedLabel(project.code, size: 11, color: Switchyard.ink.opacity(0.72))
                Spacer(minLength: 8)
                StateChip(state: state, mode: project.mode(at: now), since: Formats.ago(project.stateSince(at: now), from: now), onFlood: true)
            }
            Text(project.name)
                .font(.display(38, weight: .black))
                .foregroundStyle(Switchyard.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let headline = project.headline(at: now) {
                Text(headline)
                    .font(.headline(17, weight: .semibold))
                    .foregroundStyle(Switchyard.ink.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if !steps.isEmpty {
                Strip.steps(steps, color: Switchyard.ink.opacity(0.75), track: Switchyard.ink.opacity(0.18), height: 6)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// "TDR  Tachyon Drifter  3 d", like the Mac's sidebar.
private struct ProjectRow: View {
    let project: Project
    let now: Date

    var body: some View {
        let state = project.state(at: now)
        HStack(spacing: 12) {
            Text(project.code)
                .font(.display(22, weight: .heavy))
                .foregroundStyle(Switchyard.text)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.headline(17, weight: .semibold))
                    .foregroundStyle(Switchyard.textSecondary)
                    .lineLimit(1)
                if let line = project.headline(at: now) {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Switchyard.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !project.openTodos.isEmpty {
                Text("\(project.openTodos.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Switchyard.textTertiary)
            }
            if state != .idle {
                Circle().fill(state.swatch.color).frame(width: 8, height: 8)
                    .accessibilityLabel(state.label)
            }
            Text(Formats.ago(project.lastActivity, from: now))
                .font(.display(17, weight: .bold))
                .foregroundStyle(Switchyard.textTertiary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
    }
}
