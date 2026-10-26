import SwiftUI

struct RootView: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            Sidebar(selection: $navigator.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            Group {
                switch navigator.selection ?? .board {
                case .board: BoardScreen()
                case .activity: ActivityScreen()
                case .project(let id): ProjectScreen(id: id)
                }
            }
            .id(navigator.selection)
        }
        .navigationTitle("")
    }
}

private struct Sidebar: View {
    @Binding var selection: SidebarItem?
    @Environment(ProjectStore.self) private var store

    var body: some View {
        List(selection: $selection) {
            Label("Board", systemImage: "square.grid.2x2.fill")
                .badge(store.count(.waiting))
                .tag(SidebarItem.board)
            Label("Activity", systemImage: "waveform.path.ecg")
                .tag(SidebarItem.activity)

            let live = store.live
            if !live.isEmpty {
                Section("Now") {
                    ForEach(live) { SidebarRow(project: $0).tag(SidebarItem.project($0.id)) }
                }
            }
            Section("Projects") {
                ForEach(store.resting) { SidebarRow(project: $0).tag(SidebarItem.project($0.id)) }
            }
        }
        .safeAreaInset(edge: .bottom) { ServerStatusLine().padding(12) }
    }
}

/// "TDR  Tachyon Drifter  ●", like Sojourny's trip list.
private struct SidebarRow: View {
    let project: Project
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let state = project.state(at: store.now)
        HStack(spacing: 10) {
            Text(project.code)
                .font(.display(17, weight: .heavy))
                .foregroundStyle(Switchyard.text)
                .frame(width: 38, alignment: .leading)
            Text(project.name)
                .font(.headline(15, weight: .semibold))
                .foregroundStyle(Switchyard.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if state != .idle {
                Circle().fill(state.swatch.color).frame(width: 8, height: 8)
                    .accessibilityLabel(state.label)
            }
        }
        .contextMenu { ProjectMenuItems(project: project) }
    }
}

/// "API ● 127.0.0.1:7720".
struct ServerStatusLine: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            switch store.serverStatus {
            case .starting:
                Circle().fill(Switchyard.textTertiary).frame(width: 7, height: 7)
                Text("Starting the API…")
            case .listening(let port):
                Circle().fill(Swatch.mint.color).frame(width: 7, height: 7)
                Text(verbatim: "127.0.0.1:\(port)").font(.code(11))
            case .failed(let message):
                Circle().fill(Swatch.ember.color).frame(width: 7, height: 7)
                Text(message).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Switchyard.textTertiary)
        .help("Projects report their status to this address.")
    }
}

/// A project's menu: on its card, its sidebar row and its page.
struct ProjectMenuItems: View {
    let project: Project
    @Environment(ProjectStore.self) private var store

    var body: some View {
        if let chat = store.bestChat(for: project) {
            Button("Open Chat in Claude", systemImage: "bubble.left.and.text.bubble.right") { Reveal.chat(chat) }
        }
        if let path = project.path, project.isOnThisMac {
            Button("Show in Finder", systemImage: "folder") { Reveal.finder(path) }
            Button("Open in Terminal", systemImage: "terminal") { Reveal.terminal(path) }
        }
        if let repo = project.repo, repo.hasPrefix("http") {
            Button("Open Repository", systemImage: "arrow.up.right.square") { Reveal.url(repo) }
        }
        Divider()
        if let path = project.path {
            Button("Copy Path", systemImage: "doc.on.doc") { Reveal.copy(path) }
        }
        Button("Copy Report Command", systemImage: "terminal") {
            Reveal.copy("factory report --project \(project.id) --state working --task \"…\"")
        }
        Divider()
        if project.hidden {
            Button("Show on Board", systemImage: "eye") { store.setHidden(project.id, false) }
        } else {
            Button("Hide from Board", systemImage: "eye.slash") { store.setHidden(project.id, true) }
        }
    }
}
