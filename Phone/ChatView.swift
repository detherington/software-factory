import SwiftUI

/// A chat one of your Macs runs, on the iPhone: the conversation as the Mac last sent it, its
/// permission prompts, and a box to write in, which the Mac passes to Claude as your own words. With
/// no chat yet, the first thing you write starts one on a Mac that has the project's folder.
struct ChatView: View {
    let project: String
    @State var id: String?
    @Environment(PhoneBoard.self) private var board
    @State private var draft = ""
    @FocusState private var writing: Bool

    var body: some View {
        let chat = id.flatMap { board.chats[$0] }
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if let chat {
                        ChatTranscript(chat: chat, activity: board[project]?.sessions.first { $0.id == chat.id }?.activity)
                            .padding(16)
                        if chat.status == .starting, chat.machine == nil {
                            Text("Waiting for a Mac with this project's folder to start it. Software Factory needs to be open there.")
                                .font(.system(size: 13))
                                .foregroundStyle(Switchyard.textSecondary)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        Text("Write to start a Claude Code session in \(board[project]?.name ?? String(localized: "this project")). A Mac with its folder runs it, with your usual settings.")
                            .font(.system(size: 14))
                            .foregroundStyle(Switchyard.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat?.items.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if let chat, let ask = chat.ask, let project = board[project] {
                PermissionPrompt(ask: ask, sent: board.answeredPermissions[ask.id]) { reply in
                    board.answer(ask, reply: reply, in: project)
                }
                .padding(16)
                .background(Swatch.amber.color.opacity(0.08))
            }
            if let problem = chat?.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Swatch.ember.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Swatch.ember.color.opacity(0.1))
            }
            composer(chat)
        }
        .background(Switchyard.background.ignoresSafeArea())
        .navigationTitle(chat?.title ?? String(localized: "New chat"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let chat {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        ChatModeMenu(mode: chat.mode ?? .auto) { board.setMode($0, in: chat) }
                        StatusChip(text: chat.status.label, swatch: chat.status.swatch)
                    }
                }
            }
        }
        // While it's open, the conversation comes in as the Mac sends it.
        .task {
            while !Task.isCancelled {
                await board.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func composer(_ chat: HostedChat?) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(String(localized: "Write to Claude"), text: $draft, axis: .vertical)
                .font(.system(size: 16))
                .lineLimit(1...6)
                .focused($writing)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Switchyard.surfaceRaised, in: .rect(cornerRadius: 18, style: .continuous))
            if let chat, chat.status.isBusy || chat.status == .waiting {
                Button { board.interrupt(chat) } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Switchyard.ink)
                        .frame(width: 40, height: 40)
                        .background(Swatch.ember.color, in: .circle)
                }
                .accessibilityLabel(String(localized: "Stop"))
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Switchyard.ink)
                    .frame(width: 40, height: 40)
                    .background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Switchyard.surfaceRaised : Swatch.violet.color, in: .circle)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(String(localized: "Send"))
        }
        .padding(12)
        .background(Switchyard.surface)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id, let chat = board.chats[id] {
            board.write(text, in: chat)
        } else if let project = board[project] {
            id = board.startChat(in: project, text: text)
        }
        draft = ""
    }
}

/// A project's chats, on its page: each opens, and a new one starts on a Mac with its folder.
struct ProjectChats: View {
    let project: Project
    let now: Date
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let chats = board.chats(for: project.id)
        Card(padding: 16) {
            ForEach(chats.prefix(5)) { chat in
                NavigationLink { ChatView(project: project.id, id: chat.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(chat.status.swatch.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title ?? String(localized: "New chat"))
                                .font(.headline(16, weight: .semibold))
                                .foregroundStyle(Switchyard.text)
                                .lineLimit(1)
                            Text([chat.status.label, chat.machine].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(Switchyard.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Text(Formats.ago(chat.updated, from: now)).font(.display(16, weight: .heavy)).foregroundStyle(Switchyard.textTertiary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            NavigationLink { ChatView(project: project.id, id: nil) } label: {
                Label(String(localized: "New chat with Claude Code"), systemImage: "plus.bubble")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Swatch.violet.color)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
        }
    }
}
