import SwiftUI

/// The overview: what needs you, what's under way, and every other project.
struct BoardScreen: View {
    var body: some View {
        ScrollView {
            BoardContent()
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .readableWidth()
        }
        .scrollIndicators(.hidden)
        .screenBackground()
    }
}

struct BoardContent: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let live = store.live
        let resting = store.resting
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(label: store.now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: title) {
                GlassIconButton(systemImage: "arrow.clockwise", accessibilityLabel: String(localized: "Look for projects")) {
                    store.discover()
                }
            }
            StatsRow()
                .padding(.bottom, 8)

            if !live.isEmpty {
                SectionLabel("Now")
                LazyVGrid(columns: .cards, alignment: .leading, spacing: 14) {
                    ForEach(live) { LiveCard(project: $0) }
                }
            }
            if !resting.isEmpty {
                SectionLabel("Projects", trailing: "\(resting.count)")
                LazyVGrid(columns: .cards, alignment: .leading, spacing: 14) {
                    ForEach(resting) { ProjectCard(project: $0) }
                }
            }
            if store.board.isEmpty {
                EmptyBoard()
            }
        }
    }

    private var title: String {
        if store.count(.waiting) + store.count(.yourCall) > 0 { return String(localized: "Your move") }
        if store.count(.working) > 0 { return String(localized: "Hard at work") }
        if store.count(.background) > 0 { return String(localized: "Ticking over") }
        if store.count(.blocked) > 0 { return String(localized: "Stuck") }
        return String(localized: "All quiet")
    }
}

/// Counts, Passport style: giant numerals over tracked labels.
private struct StatsRow: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        // Wraps onto a second row in a narrow window.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 28, alignment: .leading)], alignment: .leading, spacing: 12) {
            stat(store.count(.waiting), "Needs you", .amber)
            stat(store.count(.yourCall), "Your call", .tangerine)
            stat(store.count(.working), "Working", .violet)
            stat(store.count(.background), "Background", .sky)
            stat(store.count(.blocked), "Blocked", .ember)
            stat(store.activeToday, "Active today", nil)
            stat(store.board.count, "Projects", nil)
        }
    }

    private func stat(_ value: Int, _ label: String, _ swatch: Swatch?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.display(64, weight: .heavy))
                .foregroundStyle(value == 0 ? Switchyard.textTertiary : swatch?.color ?? Switchyard.text)
                .rollingDigits()
                .animation(.snappy, value: value)
            TrackedLabel(label, size: 11, color: Switchyard.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A live project as a flood of its state's color, like Sojourny's Now card.
struct LiveCard: View {
    let project: Project
    @Environment(ProjectStore.self) private var store
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let now = store.now
        let state = project.state(at: now)
        let live = project.liveSessions(at: now)
        let steps = project.displaySteps(at: now)
        let permission = project.openPermission(at: now)
        // A prompt's buttons can't sit inside the card's own button: with one, a tap opens the card.
        if permission != nil {
            content(state: state, live: live, steps: steps, permission: permission, now: now)
                .onTapGesture { navigator.open(project.id) }
                .accessibilityAddTraits(.isButton)
                .contextMenu { ProjectMenuItems(project: project) }
        } else {
            Button { navigator.open(project.id) } label: { content(state: state, live: live, steps: steps, permission: nil, now: now) }
                .buttonStyle(.plain)
                .contextMenu { ProjectMenuItems(project: project) }
        }
    }

    private func content(state: ProjectState, live: [Session], steps: [Step], permission: (session: Session, ask: PermissionAsk)?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TrackedLabel(topLine(live: live), size: 11, color: Switchyard.ink.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StateChip(state: state, mode: project.mode(at: now), since: Formats.ago(project.stateSince(at: now), from: now),
                          onFlood: true)
            }
            Text(project.name)
                .font(.display(50, weight: .black))
                .foregroundStyle(Switchyard.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if let headline = project.headline(at: now) {
                Text(headline)
                    .font(.headline(20, weight: .semibold))
                    .foregroundStyle(Switchyard.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if let ask = permission?.ask {
                PermissionPrompt(ask: ask, onFlood: true, answerable: PermissionDesk.shared.isWaiting(for: ask.id), compact: true) { reply in
                    store.answerPermission(ask.id, reply: reply, from: String(localized: "this Mac"))
                }
                .padding(.top, 4)
            }
            if !steps.isEmpty {
                Strip.steps(steps, color: Switchyard.ink, track: Switchyard.ink.opacity(0.18))
                    .padding(.top, 4)
            } else if let fraction = project.fraction(at: now) {
                Strip.fraction(fraction, color: Switchyard.ink, track: Switchyard.ink.opacity(0.18))
                    .padding(.top, 4)
            }
            Spacer(minLength: 4)
            ThenBar(project: project, now: now)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 268, alignment: .topLeading)
        .background(state.swatch.gradient, in: .rect(cornerRadius: Switchyard.cardRadius, style: .continuous))
        .contentShape(.rect(cornerRadius: Switchyard.cardRadius))
    }

    private func topLine(live: [Session]) -> String {
        var parts = [project.code]
        if live.count > 1 { parts.append(String(localized: "\(live.count) sessions")) }
        // Another Mac's session says where it is.
        if let machine = live.first?.machine { parts.append(machine) }
        if let milestone = project.milestone { parts.append(milestone) }
        return parts.joined(separator: " · ")
    }
}

/// The dark bar at the foot of a flood card: what it just did, or what's next.
private struct ThenBar: View {
    let project: Project
    let now: Date

    var body: some View {
        let lead = project.liveSessions(at: now).first
        let next = project.displaySteps(at: now).first { $0.status != .done }
        let (label, text, symbol): (String, String, String) =
            if let lead, lead.state == .background, let jobs = lead.jobsSummary(at: now) {
                (String(localized: "Waiting on"), jobs, "hourglass")
            } else if let activity = lead?.activity, lead?.state == .working {
                (String(localized: "Just now"), activity, "waveform")
            } else if let next {
                (next.status == .active ? String(localized: "Under way") : String(localized: "Next"), next.title, "arrow.right")
            } else if let commit = project.lastCommit {
                (String(localized: "Last commit"), commit.subject, "chevron.left.forwardslash.chevron.right")
            } else {
                (String(localized: "Folder"), project.displayPath ?? project.id, "folder.fill")
            }
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(project.state(at: now).swatch.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                TrackedLabel(label, size: 9, color: Switchyard.textTertiary)
                Text(text)
                    .font(.headline(15, weight: .semibold))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Formats.ago(lead?.updated ?? project.lastActivity, from: now))
                .font(.display(20, weight: .heavy))
                .foregroundStyle(Switchyard.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Switchyard.ink.opacity(0.9), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// A resting project, like Sojourny's trip card: a giant code with its split-flap seam.
struct ProjectCard: View {
    let project: Project
    @Environment(ProjectStore.self) private var store
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let now = store.now
        let state = project.state(at: now)
        let steps = project.displaySteps(at: now)
        Button { navigator.open(project.id) } label: {
            Card(padding: 18) {
                HStack(alignment: .top) {
                    SplitFlapCode(code: project.code, size: 60)
                    Spacer(minLength: 8)
                    if state == .idle {
                        if let version = project.version {
                            CodeChip(text: version)
                        } else if let branch = project.branch, branch != "main", branch != "master" {
                            CodeChip(text: branch, symbol: "arrow.triangle.branch")
                        }
                    } else {
                        StatusChip(text: state.label, swatch: state.swatch, symbol: state.symbol)
                    }
                }
                Text(project.name)
                    .font(.headline(23, weight: .bold))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(1)
                Text(project.displaySummary ?? project.displayPath ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                let ends = project.openLooseEnds
                let todos = project.openTodos.count
                // Wrapped, so a project with loose ends on several Macs doesn't push the card wide.
                if !ends.isEmpty || todos > 0 || project.appStore != nil {
                    FlowChips {
                        if todos > 0 { StatusChip(text: String(localized: "\(todos) to do"), symbol: "checklist") }
                        LooseEndsChips(ends: ends)
                        if let status = project.appStore { AppStoreChips(status: status, now: now) }
                    }
                    .padding(.top, 2)
                }
                if !steps.isEmpty {
                    Strip.steps(steps, color: state == .idle ? Switchyard.textSecondary : state.swatch.color, track: Switchyard.surfaceRaised)
                        .padding(.vertical, 4)
                }
                Rectangle().fill(Switchyard.stroke).frame(height: 1).padding(.vertical, 2)
                HStack(spacing: 10) {
                    SymbolTile(symbol: project.displaySymbol, swatch: state.swatch, size: 28)
                    Text(lastLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Switchyard.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Formats.ago(project.lastActivity, from: now))
                        .font(.display(19, weight: .heavy))
                        .foregroundStyle(Switchyard.textTertiary)
                }
            }
            .contentShape(.rect(cornerRadius: Switchyard.cardRadius))
        }
        .buttonStyle(.plain)
        .contextMenu { ProjectMenuItems(project: project) }
    }

    private var lastLine: String {
        if let note = project.note { return note }
        if let event = project.events.first { return event.title }
        return String(localized: "Last Claude Code session")
    }
}

private struct EmptyBoard: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No projects yet")
                .font(.headline(26))
                .foregroundStyle(Switchyard.text)
            Text("Projects appear here when Claude Code has had a session in them, or when they report in. Try:")
                .foregroundStyle(Switchyard.textSecondary)
            Text(verbatim: "factory working \"Getting started\"")
                .font(.code(13))
                .foregroundStyle(Switchyard.text)
                .padding(10)
                .background(Switchyard.surfaceRaised, in: .rect(cornerRadius: 10))
                .textSelection(.enabled)
        }
        .padding(.vertical, 40)
    }
}
