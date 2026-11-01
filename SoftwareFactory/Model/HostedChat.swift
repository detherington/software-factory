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
