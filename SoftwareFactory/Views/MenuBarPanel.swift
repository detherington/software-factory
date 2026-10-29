import SwiftUI

/// The menu bar icon: a raised hand and a count when something needs you, a bolt while work's under way.
struct MenuBarLabel: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            // Always on screen, so it's how a notification opens the board window.
            .onAppear { Navigator.shared.openBoard = { openWindow(id: "board") } }
    }

    @ViewBuilder
    private var label: some View {
        let waiting = store.count(.waiting)
        let yourCall = store.count(.yourCall)
        let working = store.count(.working)
        if waiting > 0 {
            // Everything waiting on you, under the most urgent kind's glyph.
            Label("\(waiting + yourCall)", systemImage: "hand.raised.fill").labelStyle(.titleAndIcon)
        } else if yourCall > 0 {
            Label("\(yourCall)", systemImage: "questionmark.bubble.fill").labelStyle(.titleAndIcon)
        } else if working > 0 {
            Label("\(working)", systemImage: "bolt.fill").labelStyle(.titleAndIcon)
        } else if store.count(.background) > 0 {
            Label("\(store.count(.background))", systemImage: "hourglass").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "square.grid.2x2")
        }
    }
}

/// The panel under the menu bar icon: what's live, at a glance.
struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Navigator.self) private var navigator

    var body: some View {
        MenuBarContent { id in
            if let id { navigator.open(id) } else { navigator.selection = .board }
            openWindow(id: "board")
            NSApplication.shared.activate()
        }
        .frame(width: 380)
        .background(Switchyard.background)
    }
}

struct MenuBarContent: View {
    @Environment(ProjectStore.self) private var store
    let open: (String?) -> Void

    var body: some View {
        let now = store.now
        let live = store.live
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                TrackedLabel("Software Factory", size: 10, color: Switchyard.textTertiary)
                Text(title)
                    .font(.display(44, weight: .black))
                    .foregroundStyle(Switchyard.text)
            }
            if live.isEmpty {
                Text("Nothing under way. \(store.board.count) projects resting.")
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textSecondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(live.prefix(8)) { project in
                        HStack(alignment: .center, spacing: 6) {
                            Button { open(project.id) } label: { row(project, now: now) }
                                .buttonStyle(.plain)
                            // Straight to the chat, where whatever needs you gets answered: only the live
                            // session's own, never an older chat in the same folder.
                            if let chat = store.liveChat(for: project) {
                                Button { Reveal.chat(chat) } label: {
                                    Image(systemName: "bubble.left.and.text.bubble.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Switchyard.textSecondary)
                                        .frame(width: 34, height: 34)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "Open “\(chat.title ?? project.name)” in Claude"))
                            }
                        }
                        .padding(10)
                        .background(Switchyard.surface, in: .rect(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            let recent = store.resting.prefix(live.isEmpty ? 5 : 3)
            if !recent.isEmpty {
                TrackedLabel("Recent", size: 10, color: Switchyard.textTertiary).padding(.top, 2)
                ForEach(recent) { project in
                    Button { open(project.id) } label: {
                        HStack(spacing: 10) {
                            Text(project.code).font(.display(17, weight: .heavy)).foregroundStyle(Switchyard.text).frame(width: 38, alignment: .leading)
                            Text(project.name).font(.headline(15, weight: .semibold)).foregroundStyle(Switchyard.textSecondary).lineLimit(1)
                            Spacer()
                            Text(Formats.ago(project.lastActivity, from: now)).font(.display(16, weight: .bold)).foregroundStyle(Switchyard.textTertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            QuickTodo()
            Rectangle().fill(Switchyard.stroke).frame(height: 1)
            HStack(spacing: 10) {
                Button("Open Board") { open(nil) }
                    .signButtonStyle()
                SettingsLink { Text("Settings…") }
                    .buttonStyle(.glass)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.glass)
            }
            ServerStatusLine()
        }
        .padding(16)
    }

    private var title: String {
        let waiting = store.count(.waiting)
        if waiting > 0 { return waiting == 1 ? String(localized: "1 needs you") : String(localized: "\(waiting) need you") }
        let yourCall = store.count(.yourCall)
        if yourCall > 0 { return yourCall == 1 ? String(localized: "1 awaits your call") : String(localized: "\(yourCall) await your call") }
        let working = store.count(.working)
        if working > 0 { return String(localized: "\(working) at work") }
        let background = store.count(.background)
        if background > 0 { return String(localized: "\(background) in the background") }
        return String(localized: "All quiet")
    }

    private func row(_ project: Project, now: Date) -> some View {
        let state = project.state(at: now)
        return HStack(alignment: .top, spacing: 12) {
            CodeTile(code: project.code, swatch: state.swatch, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(project.name).font(.headline(17, weight: .bold)).foregroundStyle(Switchyard.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Formats.ago(project.stateSince(at: now), from: now))
                        .font(.display(17, weight: .heavy))
                        .foregroundStyle(state.swatch.color)
                }
                Text(project.headline(at: now) ?? state.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state == .waiting ? state.swatch.color : Switchyard.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .contentShape(.rect)
    }
}
