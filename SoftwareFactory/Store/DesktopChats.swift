import Foundation

/// Claude Desktop's Code chats, from the file it keeps for each one in
/// ~/Library/Application Support/Claude/claude-code-sessions, so the board can open the chat a
/// session runs in. A chat's file gives its own id (local_…), which `claude://code/continue?session=`
/// opens, and the Claude Code session id that the hooks report (`cliSessionId`).
nonisolated enum DesktopChats {
    struct Chat: Identifiable, Hashable, Sendable {
        /// "local_5c1714e4-…".
        var id: String
        var cliSessionID: String?
        var title: String?
        var cwd: String?
        var lastActivity: Date?
        var isArchived: Bool

        /// Opens the chat in Claude Desktop.
        var url: URL? {
            URL(string: "claude://code/continue?session=\(id)")
        }
    }

    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/Claude/claude-code-sessions", directoryHint: .isDirectory)
    }

    static func scan() -> [Chat] {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return files.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            .compactMap(read)
    }

    /// The fields come first in each file, before its tool settings, which can run to half a megabyte:
    /// read the head, and the whole file only if the head doesn't have them.
    private static func read(_ file: URL) -> Chat? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 32 * 1024)) ?? Data(), as: UTF8.self)
        let id = file.deletingPathExtension().lastPathComponent
        if let cli = string("cliSessionId", in: head) {
            return Chat(id: id, cliSessionID: cli, title: string("title", in: head), cwd: string("originCwd", in: head) ?? string("cwd", in: head),
                        lastActivity: number("lastActivityAt", in: head).map { Date(timeIntervalSince1970: $0 / 1000) },
                        isArchived: head.contains(#""isArchived":true"#))
        }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Chat(id: id, cliSessionID: json["cliSessionId"] as? String, title: json["title"] as? String,
                    cwd: json["originCwd"] as? String ?? json["cwd"] as? String,
                    lastActivity: (json["lastActivityAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                    isArchived: json["isArchived"] as? Bool ?? false)
    }

    /// A top-level string field's value, unescaped.
    private static func string(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":\""), let match = text[range.upperBound...].prefixMatch(of: /((?:[^"\\]|\\.)*)"/) else {
            return nil
        }
        return try? JSONDecoder().decode(String.self, from: Data("\"\(match.1)\"".utf8))
    }

    private static func number(_ key: String, in text: String) -> Double? {
        guard let range = text.range(of: "\"\(key)\":"), let match = text[range.upperBound...].prefixMatch(of: /\d+/) else { return nil }
        return Double(match.0)
    }
}
