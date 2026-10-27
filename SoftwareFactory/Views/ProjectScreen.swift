import SwiftUI

/// One project: where it stands now, its plan, its sessions and its timeline.
struct ProjectScreen: View {
    let id: String
    @Environment(ProjectStore.self) private var store

    var body: some View {
        if let project = store[id] {
            ScrollView {
                ProjectContent(project: project)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 40)
                    .readableWidth(1120)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
        } else {
            ContentUnavailableView("No Such Project", systemImage: "questionmark.folder", description: Text("It may have been removed."))
                .screenBackground()
        }
    }
}

struct ProjectContent: View {
    let project: Project
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let now = store.now
        let state = project.state(at: now)
        let steps = project.displaySteps(at: now)
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(label: [project.code, project.displayPath].compactMap { $0 }.joined(separator: " · "), title: project.name) {
                HStack(spacing: 8) {
                    if let chat = store.bestChat(for: project) {
                        GlassIconButton(systemImage: "bubble.left.and.text.bubble.right",
                                        accessibilityLabel: String(localized: "Open “\(chat.title ?? project.name)” in Claude")) { Reveal.chat(chat) }
                    }
                    if let path = project.path, project.isOnThisMac {
                        GlassIconButton(systemImage: "folder", accessibilityLabel: String(localized: "Show in Finder")) { Reveal.finder(path) }
                        GlassIconButton(systemImage: "terminal", accessibilityLabel: String(localized: "Open in Terminal")) { Reveal.terminal(path) }
                    }
                    GlassMenuButton(systemImage: "ellipsis", accessibilityLabel: String(localized: "More")) {
                        ProjectMenuItems(project: project)
                    }
                }
            }

            if !steps.isEmpty {
                Strip.steps(steps, color: state == .idle ? Switchyard.textSecondary : state.swatch.color, track: Switchyard.surfaceRaised, height: 10)
            }
            chips(state: state, now: now)

            NowPanel(project: project, now: now)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                if let fraction = project.fraction(at: now) {
                    ProgressCard(project: project, fraction: fraction, steps: steps, swatch: state == .idle ? .slate : state.swatch)
                }
                if !project.sessions.isEmpty {
                    SessionsCard(project: project, now: now)
                }
                let shown = Set(project.sessions.compactMap { store.chat(for: $0)?.id })
                let others = store.chats(for: project).filter { !shown.contains($0.id) }
                if !others.isEmpty {
                    ChatsCard(chats: Array(others.prefix(5)), now: now)
                }
                AboutCard(project: project, now: now)
            }

            if !project.events.isEmpty {
                SectionLabel("Timeline", trailing: String(localized: "\(project.events.count) entries"))
                Timeline(events: project.events.map { (project, $0) }, now: now, showProject: false)
            }
        }
    }

    private func chips(state: ProjectState, now: Date) -> some View {
        let live = project.liveSessions(at: now)
        return FlowChips {
            StatusChip(text: "\(state.label) · \(Formats.ago(project.stateSince(at: now), from: now))",
                       swatch: state.swatch, symbol: state.symbol, prominent: state != .idle)
            if let milestone = project.milestone {
                StatusChip(text: milestone, symbol: "flag.fill")
            }
            if live.count > 0 {
                StatusChip(text: live.count == 1 ? String(localized: "1 session") : String(localized: "\(live.count) sessions"),
                           symbol: "rectangle.stack.fill")
            }
            if let branch = project.branch { CodeChip(text: branch, symbol: "arrow.triangle.branch") }
            if let version = project.version { CodeChip(text: version, symbol: "shippingbox.fill") }
            ForEach(project.links.sorted { $0.key < $1.key }, id: \.key) { name, link in
                Button { Reveal.url(link) } label: { StatusChip(text: name.capitalized, swatch: .sky, symbol: "link") }
                    .buttonStyle(.plain)
            }
        }
    }
}

/// Chips that wrap onto more rows.
private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: 8) { content }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var (x, y, rowHeight, maxX): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var (x, y, rowHeight) = (bounds.minX, bounds.minY, CGFloat(0))
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// What's happening now, as a flood like Sojourny's Now screen; or, at rest, the last thing that happened.
private struct NowPanel: View {
    let project: Project
    let now: Date

    var body: some View {
        let state = project.state(at: now)
        let lead = project.leadSession(at: now)
        if state.isLive {
            VStack(alignment: .leading, spacing: 6) {
                TrackedLabel(label(state), size: 12, color: Switchyard.ink.opacity(0.72))
                Text(elapsed(now.timeIntervalSince(project.stateSince(at: now))))
                    .font(.display(110, weight: .black))
                    .foregroundStyle(Switchyard.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let headline = project.headline(at: now) {
                    Text(headline)
                        .font(.headline(24, weight: .semibold))
                        .foregroundStyle(Switchyard.ink)
                        .textSelection(.enabled)
                }
                if let lead, lead.state == .background, let jobs = lead.jobsSummary(at: now) {
                    Label(String(localized: "Waiting on \(jobs)"), systemImage: "hourglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Switchyard.ink.opacity(0.8))
                        .padding(.top, 2)
                } else if let activity = lead?.activity, lead?.state == .working {
                    Label(activity, systemImage: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Switchyard.ink.opacity(0.8))
                        .padding(.top, 2)
                }
                if state == .blocked, let note = project.note, note != project.headline(at: now) {
                    Text(note).font(.system(size: 14, weight: .medium)).foregroundStyle(Switchyard.ink.opacity(0.8))
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.swatch.gradient, in: .rect(cornerRadius: Switchyard.cardRadius, style: .continuous))
        } else if let line = state == .done ? (project.note ?? project.task) : (project.task ?? project.note ?? lead?.task) {
            // Shipped leads with what shipped (the note), not the task before it.
            Card(padding: 20) {
                TrackedLabel(state == .done ? String(localized: "Shipped") : String(localized: "Last worked on"), size: 11, color: Switchyard.textTertiary)
                Text(line)
                    .font(.headline(26, weight: .bold))
                    .foregroundStyle(Switchyard.text)
                    .textSelection(.enabled)
                Text(project.lastActivity.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textTertiary)
            }
        }
    }

    /// Minutes and up; under a minute is just "Now".
    private func elapsed(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(localized: "Now") : Formats.duration(seconds)
    }

    private func label(_ state: ProjectState) -> String {
        switch state {
        case .waiting: String(localized: "Waiting for you for")
        case .blocked: String(localized: "Blocked for")
        case .background: String(localized: "In the background for")
        default: String(localized: "Working for")
        }
    }
}

/// Progress, Passport style, and the checklist.
private struct ProgressCard: View {
    let project: Project
    let fraction: Double
    let steps: [Step]
    let swatch: Swatch

    var body: some View {
        Card(padding: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Formats.percent(fraction))
                    .font(.display(64, weight: .heavy))
                    .foregroundStyle(swatch == .slate ? Switchyard.text : swatch.color)
                    .rollingDigits()
                VStack(alignment: .leading, spacing: 2) {
                    TrackedLabel(project.milestone ?? String(localized: "Progress"), size: 11, color: Switchyard.textTertiary)
                    if !steps.isEmpty {
                        TrackedLabel(String(localized: "\(steps.filter { $0.status == .done }.count) of \(steps.count) steps"), size: 10, color: Switchyard.textTertiary)
                    }
                }
            }
            if steps.isEmpty {
                Strip.fraction(fraction, color: swatch == .slate ? Switchyard.textSecondary : swatch.color, track: Switchyard.surfaceRaised)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(step.status))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(step.status == .todo ? Switchyard.textTertiary : swatch == .slate ? Switchyard.text : swatch.color)
                            .frame(width: 18)
                        Text(step.title)
                            .font(.headline(17, weight: step.status == .active ? .bold : .medium))
                            .foregroundStyle(step.status == .done ? Switchyard.textSecondary : Switchyard.text)
                            .strikethrough(step.status == .done, color: Switchyard.textTertiary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func symbol(_ status: Step.Status) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .active: "circle.dotted.circle"
        case .todo: "circle"
        }
    }
}

private struct SessionsCard: View {
    let project: Project
    let now: Date
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let live = Set(project.liveSessions(at: now).map(\.id))
        Card(padding: 20) {
            TrackedLabel(String(localized: "Sessions"), size: 11, color: Switchyard.textTertiary)
            ForEach(project.sessions.sorted { $0.updated > $1.updated }) { session in
                // A Claude Desktop session opens its chat; a Terminal or other Mac's session is just a row.
                if let chat = store.chat(for: session) {
                    Button { Reveal.chat(chat) } label: { row(session, chat: chat, live: live) }
                        .buttonStyle(.plain)
                        .help(String(localized: "Open this chat in Claude"))
                } else {
                    row(session, chat: nil, live: live)
                }
            }
        }
    }

    private func row(_ session: Session, chat: DesktopChats.Chat?, live: Set<String>) -> some View {
        let state = live.contains(session.id) ? session.state : .idle
        return HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: state.symbol, swatch: state.swatch, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                // The chat's title in Claude Desktop names it best; the task says what it's on now.
                Text(chat?.title ?? session.task ?? String(localized: "No task yet"))
                    .font(.headline(17, weight: .semibold))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(2)
                if chat?.title != nil, let task = session.task, state != .idle {
                    Text(task).font(.system(size: 13)).foregroundStyle(Switchyard.textSecondary).lineLimit(1)
                }
                if let message = session.message, state == .waiting {
                    Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(Swatch.amber.color)
                } else if state == .background, let jobs = session.jobsSummary(at: now) {
                    Label(String(localized: "Waiting on \(jobs)"), systemImage: "hourglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Swatch.sky.color)
                        .lineLimit(1)
                } else if let activity = session.activity, state == .working {
                    Text(activity).font(.system(size: 13)).foregroundStyle(Switchyard.textSecondary).lineLimit(1)
                }
                Text([session.machine, session.worktree ?? String(localized: "Main folder")].compactMap { $0 }.joined(separator: " · "))
                    .font(.code(11))
                    .foregroundStyle(Switchyard.textTertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Formats.ago(session.updated, from: now)).font(.display(20, weight: .heavy)).foregroundStyle(Switchyard.textSecondary)
                TrackedLabel(state.label, size: 9, color: state == .idle ? Switchyard.textTertiary : state.swatch.color)
            }
            if chat != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Switchyard.textTertiary)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 6)
        .contentShape(.rect)
    }
}

/// The project's other Claude Desktop chats, to pick one up again.
private struct ChatsCard: View {
    let chats: [DesktopChats.Chat]
    let now: Date

    var body: some View {
        Card(padding: 20) {
            TrackedLabel(String(localized: "Recent chats"), size: 11, color: Switchyard.textTertiary)
            ForEach(chats) { chat in
                Button { Reveal.chat(chat) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: chat.isArchived ? "archivebox" : "bubble.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Switchyard.textTertiary)
                            .frame(width: 18)
                        Text(chat.title ?? String(localized: "Untitled chat"))
                            .font(.headline(16, weight: .semibold))
                            .foregroundStyle(chat.isArchived ? Switchyard.textSecondary : Switchyard.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let date = chat.lastActivity {
                            Text(Formats.ago(date, from: now)).font(.display(18, weight: .heavy)).foregroundStyle(Switchyard.textTertiary)
                        }
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Switchyard.textTertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open this chat in Claude"))
            }
        }
    }
}

private struct AboutCard: View {
    let project: Project
    let now: Date

    var body: some View {
        Card(padding: 20) {
            TrackedLabel(String(localized: "About"), size: 11, color: Switchyard.textTertiary)
            if let summary = project.displaySummary {
                Text(summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Switchyard.text)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let path = project.displayPath {
                    row("Folder", path, mono: true)
                }
                if let repo = project.repo {
                    row("Repository", repo.replacingOccurrences(of: "https://", with: ""), mono: true)
                }
                if let commit = project.lastCommit {
                    row("Last commit", "\(commit.subject)  ·  \(commit.hash.prefix(7))  ·  \(Formats.ago(commit.date, from: now))", mono: false)
                }
                row("Kind", (project.kind ?? project.detectedKind ?? .other).rawValue.capitalized, mono: false)
                row("Id", project.id, mono: true)
            }
            .padding(.top, 6)
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TrackedLabel(label, size: 9, color: Switchyard.textTertiary)
            Text(value)
                .font(mono ? .code(12) : .system(size: 13, weight: .medium))
                .foregroundStyle(Switchyard.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
