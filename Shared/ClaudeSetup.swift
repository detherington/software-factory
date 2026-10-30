import Foundation

/// Installs Software Factory's hooks in Claude Code's user settings (~/.claude/settings.json), so
/// every session reports in on its own. Shared by the app's Settings and `factory install-hooks`.
///
/// Each hook posts its JSON input to the board and always exits 0, printing nothing; but the
/// PermissionRequest hook waits for the board's answer to the prompt, and prints that.
/// - On the board's own Mac it's curl to 127.0.0.1: with the app closed, curl fails in a
///   millisecond and Claude Code carries on.
/// - On another Mac it's `factory hook`, which reads the board's address and token from
///   ~/.config/software-factory.json and, when the board can't be reached, stops trying for a
///   minute rather than slow every tool call.
nonisolated enum ClaudeSetup {
    /// Marks our entries, so installing twice replaces them and removing finds them.
    static let marker = "# software-factory"
    /// What marked them before.
    private static let markers = [marker, "/api/hooks/claude"]

    /// $HOME, as Claude Code reads it (NSHomeDirectory ignores it).
    static var home: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    }

    static var settingsURL: URL {
        home.appending(path: ".claude/settings.json")
    }

    /// For the board's own Mac.
    static func command(port: UInt16) -> String {
        "curl -s -o /dev/null --connect-timeout 1 -m 3 -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:\(port)/api/hooks/claude || true \(marker)"
    }

    /// For another Mac: the `factory` command at `path` forwards the input.
    static func command(factory path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' hook >/dev/null 2>&1 || true \(marker)"
    }

    /// How long the PermissionRequest hook waits for an answer from the board.
    static let permissionWait: TimeInterval = 30 * 60

    /// The PermissionRequest hook on the board's own Mac: it prints what the board answers (Claude
    /// Code's decision, or nothing), and says which app runs Claude Code. `-f`: an error prints nothing.
    static func permissionCommand(port: UInt16) -> String {
        "curl -sf --connect-timeout 1 -m \(Int(permissionWait) + 30) -H 'Content-Type: application/json' "
            + "-H \"X-Claude-Entrypoint: ${CLAUDE_CODE_ENTRYPOINT:-}\" --data-binary @- http://127.0.0.1:\(port)/api/hooks/claude || true \(marker)"
    }

    /// The PermissionRequest hook on another Mac: `factory hook` prints the board's answer.
    static func permissionCommand(factory path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' hook 2>/dev/null || true \(marker)"
    }

    /// The PermissionRequest command that goes with one of our event commands.
    static func permissionCommand(like command: String) -> String {
        if let port = command.firstMatch(of: /127\.0\.0\.1:(\d+)\/api\/hooks\/claude/).flatMap({ UInt16($0.1) }) {
            return permissionCommand(port: port)
        }
        if let quoted = command.firstMatch(of: /^'((?:[^']|'\\'')*)' hook/)?.1 {
            return permissionCommand(factory: String(quoted).replacingOccurrences(of: "'\\''", with: "'"))
        }
        return command
    }

    /// A Mac's name as it travels in the X-Factory-Machine header: percent-encoded, so any name fits.
    static func headerValue(machine: String) -> String {
        machine.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "Mac"
    }

    /// The events we listen to, with a tool matcher where the event takes one.
    static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        // Bash before it runs, to say a build or test is under way while it is.
        ("PreToolUse", "AskUserQuestion|ExitPlanMode|Bash"),
        ("PostToolUse", "*"),
        ("PreCompact", nil),
        ("PostCompact", nil),
        ("Notification", nil),
        ("Stop", nil),
        // A turn that ends on an API error runs this instead of Stop.
        ("StopFailure", nil),
        ("SessionEnd", nil),
        // A permission prompt, which the board can answer: this one waits for it.
        ("PermissionRequest", "*"),
    ]

    /// One of our entries in the settings: the event, its matcher, and the handler's command and timeout.
    struct Entry: Hashable {
        var event: String
        var matcher: String?
        var command: String
        var timeout: Int
    }

    /// Our entries for a set of hooks running `command`.
    static func entries(for command: String) -> [Entry] {
        let permission = permissionCommand(like: command)
        return events.map { event in
            event.name == "PermissionRequest"
                ? Entry(event: event.name, matcher: event.matcher, command: permission, timeout: Int(permissionWait) + 60)
                : Entry(event: event.name, matcher: event.matcher, command: command, timeout: 5)
        }
    }

    /// The entries of ours in a settings file's hooks.
    static func installed(in hooks: [String: Any]) -> [Entry] {
        hooks.flatMap { event, value -> [Entry] in
            (value as? [[String: Any]] ?? []).compactMap { entry in
                let handlers = entry["hooks"] as? [[String: Any]] ?? []
                guard let handler = handlers.first(where: { handler in markers.contains { (handler["command"] as? String ?? "").contains($0) } }),
                      let command = handler["command"] as? String else { return nil }
                return Entry(event: event, matcher: entry["matcher"] as? String, command: command, timeout: handler["timeout"] as? Int ?? 0)
            }
        }
    }

    /// The command to install our hooks again with, when those in `hooks` aren't what this version
    /// installs: an event added, a matcher or timeout changed. Nil when they're current, or not there.
    static func upgrade(for hooks: [String: Any]) -> String? {
        let ours = installed(in: hooks)
        guard let command = ours.first(where: { $0.event != "PermissionRequest" })?.command else { return nil }
        let wanted = entries(for: command)
        return Set(ours) == Set(wanted) && ours.count == wanted.count ? nil : command
    }

    /// `hooks` with ours added.
    static func hooks(_ hooks: [String: Any], adding command: String) -> [String: Any] {
        var hooks = hooks
        for entry in entries(for: command) {
            var item: [String: Any] = ["hooks": [["type": "command", "command": entry.command, "timeout": entry.timeout]]]
            if let matcher = entry.matcher { item["matcher"] = matcher }
            hooks[entry.event] = (hooks[entry.event] as? [[String: Any]] ?? []) + [item]
        }
        return hooks
    }

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL), let text = String(data: data, encoding: .utf8) else { return false }
        return markers.contains { text.contains($0) }
    }

    /// Adds our hooks (replacing any we added before) and keeps everything else as it was.
    /// Returns where the previous settings were backed up, if there were any.
    @discardableResult
    static func install(port: UInt16) throws -> URL? {
        try install(command: command(port: port))
    }

    @discardableResult
    static func install(command: String) throws -> URL? {
        var settings = try readSettings()
        settings["hooks"] = hooks(stripped(settings["hooks"] as? [String: Any] ?? [:]), adding: command)
        return try write(settings)
    }

    /// Brings the hooks we installed up to date when a new version listens to more events or runs
    /// them differently, keeping the command they run (curl here, `factory hook` on another Mac).
    /// Does nothing when they aren't installed. Returns whether it changed anything.
    @discardableResult
    static func upgradeIfNeeded() throws -> Bool {
        guard isInstalled(), let command = upgrade(for: try readSettings()["hooks"] as? [String: Any] ?? [:]) else { return false }
        try install(command: command)
        return true
    }

    /// Removes our hooks and nothing else.
    @discardableResult
    static func uninstall() throws -> URL? {
        var settings = try readSettings()
        let hooks = stripped(settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return try write(settings)
    }

    /// The hooks without ours, dropping events left empty.
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = entries.filter { entry in
                let handlers = entry["hooks"] as? [[String: Any]] ?? []
                return !handlers.contains { handler in
                    let command = handler["command"] as? String ?? ""
                    return markers.contains { command.contains($0) }
                }
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: settingsURL.path])
        }
        return object
    }

    private static func write(_ settings: [String: Any]) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if fm.fileExists(atPath: settingsURL.path) {
            let url = settingsURL.deletingPathExtension().appendingPathExtension("before-software-factory.json")
            try? fm.removeItem(at: url)
            try fm.copyItem(at: settingsURL, to: url)
            backup = url
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
        return backup
    }

    // MARK: - Telling Claude about it

    /// Where the section sits in a CLAUDE.md, so installing it again replaces it.
    static let sectionStart = "<!-- software-factory -->"
    static let sectionEnd = "<!-- /software-factory -->"

    static var instructionsURL: URL {
        home.appending(path: ".claude/CLAUDE.md")
    }

    /// For ~/.claude/CLAUDE.md (or a project's): how to report what the hooks can't see.
    /// On the board's own Mac, pass its `port`; on a connected Mac, the board's `url`, this Mac's
    /// `machine` name and where `factory` lives.
    static func claudeInstructions(port: UInt16) -> String {
        section(intro: "This Mac runs Software Factory, a status board for every project, at http://127.0.0.1:\(port).", ending: """
            Keep messages to a short line. If `factory` isn't installed, POST JSON to /api/report with curl instead \
            (`curl -s 127.0.0.1:\(port)` lists the fields). If the board isn't running, carry on without it.
            """)
    }

    static func claudeInstructions(board url: String, machine: String, factory path: String) -> String {
        section(intro: """
            Projects on this Mac report to Software Factory, a status board for every project, which runs on another Mac \
            (\(url)). This Mac reports as "\(machine)".
            """, ending: """
            Keep messages to a short line. `factory` already knows the board's address and token; if it isn't on the \
            PATH, it's at `\(path)`. If it says the board isn't answering (that Mac is asleep or away), carry on without \
            it and don't retry.
            """)
    }

    private static func section(intro: String, ending: String) -> String {
        """
        \(sectionStart)
        ## Status board

        \(intro) Hooks already report when a session is working, waiting on me or finished. Use the `factory` command \
        to add what hooks can't know, from the project's folder:

        - Your own to-do list (TodoWrite, or the task list in Claude Desktop) already reaches the board through the hooks, \
        so keep it up to date as usual and don't repeat it with `factory`.
        - Only when you're not keeping a to-do list, for work with several steps: \
        `factory steps --active "First step" --todo "Second" "Third"`, then `factory advance` each time a step is finished.
        - For a milestone: `factory report --milestone "TestFlight 0.3" --progress 40`.
        - When something is broken and you can't fix it yet: `factory blocked "Tests fail on iOS 27: missing key"`.
        - When something ships (a release, a TestFlight build, a merged PR): `factory done "Shipped 0.3 to TestFlight"`. \
        That ticks off any steps left.
        - For anything worth a line in the project's timeline: `factory note "Moved sync to CKSyncEngine"`.
        - My to-do list for the project: `factory todos` lists it (numbered), `factory todo "…"` adds to it when I ask \
        you to note something for later, and `factory todo done 2` ticks one off when you've done it.

        \(ending)
        \(sectionEnd)
        """
    }

    /// Puts the section in ~/.claude/CLAUDE.md: in place of the one there, or after what's there.
    @discardableResult
    static func installInstructions(_ section: String) throws -> URL {
        var text = (try? String(contentsOf: instructionsURL, encoding: .utf8)) ?? ""
        if let range = sectionRange(in: text) {
            text.replaceSubrange(range, with: section)
        } else {
            if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
            text += section + "\n"
        }
        try FileManager.default.createDirectory(at: instructionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: instructionsURL, atomically: true, encoding: .utf8)
        return instructionsURL
    }

    /// Takes the section out of ~/.claude/CLAUDE.md, and the file too if nothing else is in it.
    static func removeInstructions() throws {
        guard var text = try? String(contentsOf: instructionsURL, encoding: .utf8), let range = sectionRange(in: text) else { return }
        text.removeSubrange(range)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            try FileManager.default.removeItem(at: instructionsURL)
        } else {
            try (text + "\n").write(to: instructionsURL, atomically: true, encoding: .utf8)
        }
    }

    private static func sectionRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: sectionStart),
              let end = text.range(of: sectionEnd, range: start.upperBound..<text.endIndex) else { return nil }
        return start.lowerBound..<end.upperBound
    }
}
