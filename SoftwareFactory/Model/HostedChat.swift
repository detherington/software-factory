import Foundation

/// A Claude Code session Software Factory runs itself, as its chat screen shows it: on the Mac that
/// runs it and, through iCloud, on the iPhone. Its id is the session's, as Claude Code and the hooks
/// know it, so the board's session and its chat are one.
struct HostedChat: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var project: String
    /// What it was first asked, or the chat it continues.
    var title: String?
    var items: [ChatItem]
    var status: Status
    var updated: Date
    var model: String?
    /// The folder it runs in.
    var folder: String?
    /// The session it carries on from, when it continues one started elsewhere.
    var continues: String?
    /// When its session first started: after that, starting it again resumes it.
    var began: Date?
    /// How much it asks before acting; nil for the default (`ChatMode.preferred`).
    var mode: ChatMode?
    /// A tool call waiting for your permission, or a question waiting for your answer.
    var ask: PermissionAsk?
    /// Why it stopped, when it failed: "Not logged in · Please run /login".
    var problem: String?
    /// The Mac that runs it.
    var machine: String?

    enum Status: String, Codable, Sendable {
        /// Its process is starting, or its turn is under way; or a tool call waits for your permission.
        case starting, working, waiting
        /// Its turn is done: what you write next carries on.
        case idle
        /// Its process has stopped: what you write next starts it again.
        case ended, failed

        var isBusy: Bool { self == .starting || self == .working }
    }
}

/// How much a chat asks before it acts: Claude Code's permission mode.
enum ChatMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Asks before running commands or changing files.
    case ask = "default"
    /// Changes files without asking; asks before running commands.
    case acceptEdits
    /// Claude Code decides what's safe to do without asking, as Claude Desktop's chats do.
    case auto
    /// Asks nothing (`bypassPermissions`, as `--dangerously-skip-permissions` does).
    case skip = "bypassPermissions"

    var id: Self { self }

    var label: String {
        switch self {
        case .ask: String(localized: "Ask First")
        case .acceptEdits: String(localized: "Accept Edits")
        case .auto: String(localized: "Auto")
        case .skip: String(localized: "Skip Permissions")
        }
    }

    var detail: String {
        switch self {
        case .ask: String(localized: "Asks before running commands or changing files.")
        case .acceptEdits: String(localized: "Changes files without asking; asks before running commands.")
        case .auto: String(localized: "Claude Code decides what's safe to do without asking, as in Claude Desktop.")
        case .skip: String(localized: "Asks nothing: runs any command and changes any file. Use with care.")
        }
    }

    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil.and.list.clipboard"
        case .auto: "wand.and.sparkles"
        case .skip: "exclamationmark.shield.fill"
        }
    }

    /// Ember when it asks nothing.
    var swatch: Swatch { self == .skip ? .ember : .slate }

    /// What new chats start in: Settings › Claude Code, Auto unless changed.
    static var preferred: ChatMode {
        UserDefaults.standard.string(forKey: "FactoryChatMode").flatMap(ChatMode.init(rawValue:)) ?? .auto
    }
}

/// One line of a hosted chat: what you wrote, what Claude said, a tool it used, a turn's end.
struct ChatItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user, assistant, tool, result, notice, error
    }

    var id: String
    var kind: Kind
    var text: String
    /// A tool call's command or file, or what it returned when it failed.
    var detail: String?
    var date: Date
    var failed: Bool?
}

extension HostedChat {
    /// Whether anything was ever written in it.
    var hasBegun: Bool { began != nil || !items.isEmpty }

    /// The latest of it, for the iPhone: iCloud takes a megabyte a record, so long words are cut.
    func phoneCopy(items count: Int = 60, characters: Int = 4000) -> HostedChat {
        var copy = self
        copy.folder = nil
        copy.items = items.suffix(count).map { item in
            var item = item
            if item.text.count > characters { item.text = String(item.text.prefix(characters)) + "…" }
            if let detail = item.detail, detail.count > 600 { item.detail = String(detail.prefix(600)) + "…" }
            return item
        }
        return copy
    }
}
