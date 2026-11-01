import SwiftUI

/// A hosted chat's conversation, as its screens show it on the Mac and the iPhone: what you wrote on
/// the right, what Claude said in full, its tool calls in a line each, and where each turn ended.
struct ChatTranscript: View {
    let chat: HostedChat
    /// What it's doing now, from its hooks, while it works.
    var activity: String?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(chat.items) { ChatLine(item: $0) }
            if chat.status.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(chat.status == .starting ? String(localized: "Starting Claude Code…") : activity ?? String(localized: "Working…"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Swatch.violet.color)
                }
            }
        }
    }
}

struct ChatLine: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(item.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Switchyard.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Swatch.violet.color.opacity(0.24), in: .rect(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            MarkdownText(text: item.text)
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.failed == true ? "exclamationmark.triangle.fill" : "hammer.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(item.failed == true ? Swatch.ember.color : Switchyard.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Switchyard.textSecondary)
                    if let detail = item.detail {
                        Text(detail).font(.code(11)).foregroundStyle(Switchyard.textTertiary).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
        case .result:
            TrackedLabel(item.text, size: 10, color: Switchyard.textTertiary)
                .padding(.vertical, 2)
        case .notice:
            Text(item.text).font(.system(size: 13)).foregroundStyle(Switchyard.textSecondary)
        case .error:
            Label(item.text, systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Swatch.ember.color)
                .textSelection(.enabled)
        }
    }
}

/// Claude's words: Markdown inline, headings in bold, and fenced code in its own box.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.code {
                    Text(block.text)
                        .font(.code(12))
                        .foregroundStyle(Switchyard.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Switchyard.surfaceRaised, in: .rect(cornerRadius: 10, style: .continuous))
                } else {
                    Text(Self.attributed(block.text))
                        .font(.system(size: 15))
                        .foregroundStyle(Switchyard.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Prose and fenced code, in order.
    static func blocks(_ text: String) -> [(code: Bool, text: String)] {
        var blocks: [(code: Bool, text: String)] = []
        var lines: [Substring] = []
        var code = false
        func flush() {
            let joined = lines.joined(separator: "\n")
            let kept = code ? joined : joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kept.isEmpty { blocks.append((code, kept)) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                code.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return blocks
    }

    static func attributed(_ text: String) -> AttributedString {
        // Headings become bold lines; the rest is Markdown inline, keeping line breaks.
        let prose = text.replacing(/(?m)^#{1,6}\s+(.+)$/) { "**\($0.1)**" }
        return (try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// How much a chat asks before acting, as a chip that's a menu: Skip Permissions shows in ember.
struct ChatModeMenu: View {
    let mode: ChatMode
    let choose: (ChatMode) -> Void

    var body: some View {
        Menu {
            Picker(String(localized: "Permissions"), selection: Binding(get: { mode }, set: choose)) {
                ForEach(ChatMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Text(mode.detail)
        } label: {
            StatusChip(text: mode.label, swatch: mode.swatch, symbol: mode.symbol, prominent: mode == .skip)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Permissions: \(mode.label)"))
    }
}

extension HostedChat.Status {
    /// Its state's color and words, as the board's: violet at work, amber waiting on you, ember failed.
    var swatch: Swatch {
        switch self {
        case .starting, .working: .violet
        case .waiting: .amber
        case .failed: .ember
        case .idle, .ended: .slate
        }
    }

    var label: String {
        switch self {
        case .starting: String(localized: "Starting")
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Needs you")
        case .idle: String(localized: "Your turn")
        case .ended: String(localized: "Paused")
        case .failed: String(localized: "Stopped")
        }
    }
}
