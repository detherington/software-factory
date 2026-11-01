import SwiftUI

/// A Claude Code session the board runs, in a window of its own: the conversation, its permission
/// prompts, and a box to write in. What you write reaches Claude as your own words, and starts the
/// session again if it had stopped.
struct ChatScreen: View {
    let id: String
    @Environment(ProjectStore.self) private var store
    @State private var draft = ""
    @FocusState private var writing: Bool

    private var host: SessionHost { SessionHost.shared }

    var body: some View {
        if let chat = host.chats[id] {
            let project = store[chat.project]
            let session = store.local.values.lazy.flatMap(\.sessions).first { $0.id == id }
            VStack(spacing: 0) {
                header(chat, project: project)
                ScrollViewReader { proxy in
                    ScrollView {
                        if chat.items.isEmpty, !chat.status.isBusy {
                            Text("Write to start a Claude Code session in \(project?.name ?? String(localized: "this project")). It runs in \(chat.folder.map { $0.hasPrefix(ProjectPath.home) ? "~" + $0.dropFirst(ProjectPath.home.count) : $0 } ?? String(localized: "its folder")), with your usual settings, and reports to the board.")
                                .font(.system(size: 14))
                                .foregroundStyle(Switchyard.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(24)
                        }
                        ChatTranscript(chat: chat, activity: session?.activity)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: chat.items.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: chat.status) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
                if let ask = chat.ask {
                    PermissionPrompt(ask: ask, answerable: PermissionDesk.shared.isWaiting(for: ask.id)) { reply in
                        store.answerPermission(ask.id, reply: reply, from: String(localized: "this Mac"))
                    }
                    .padding(16)
                    .background(Swatch.amber.color.opacity(0.08))
                }
                if let problem = chat.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Swatch.ember.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Swatch.ember.color.opacity(0.1))
                }
                composer(chat)
            }
            .background(Switchyard.background)
            .navigationTitle(chat.title ?? project?.name ?? String(localized: "Chat"))
            .onAppear { writing = true }
        } else {
            ContentUnavailableView("No Such Chat", systemImage: "bubble.left.and.exclamationmark.bubble.right",
                                   description: Text("It may have been from before the app last started."))
                .background(Switchyard.background)
        }
    }

    private func header(_ chat: HostedChat, project: Project?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TrackedLabel([project?.code, project?.name].compactMap { $0 }.joined(separator: " · "), size: 10, color: Switchyard.textTertiary)
                Text(chat.title ?? String(localized: "New chat"))
                    .font(.headline(20, weight: .bold))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let model = chat.model {
                CodeChip(text: model.replacingOccurrences(of: "claude-", with: ""), symbol: "cpu")
            }
            StatusChip(text: chat.status.label, swatch: chat.status.swatch, prominent: chat.status != .idle && chat.status != .ended)
            if host.isHosting(id) {
                Menu {
                    Button("End Session") { host.stop(id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(String(localized: "End this session: writing again starts it where it was"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Switchyard.surface)
    }

    private func composer(_ chat: HostedChat) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(chat.status.isBusy ? String(localized: "Write while it works: Claude reads it next") : String(localized: "Write to Claude"),
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...10)
                .focused($writing)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Switchyard.surfaceRaised, in: .rect(cornerRadius: 14, style: .continuous))
            if chat.status.isBusy || chat.status == .waiting {
                Button { host.interrupt(id) } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Switchyard.ink)
                        .frame(width: 36, height: 36)
                        .background(Swatch.ember.color, in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help(String(localized: "Stop the turn under way (Escape)"))
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Switchyard.ink)
                    .frame(width: 36, height: 36)
                    .background(draft.trimmed == nil ? Switchyard.surfaceRaised : Swatch.violet.color, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmed == nil)
            .keyboardShortcut(.return, modifiers: .command)
            .help(String(localized: "Send (⌘↩)"))
        }
        .padding(16)
        .background(Switchyard.surface)
    }

    private func send() {
        guard let text = draft.trimmed else { return }
        if host.send(text, to: id) { draft = "" }
    }
}
