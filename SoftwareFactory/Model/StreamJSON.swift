import Foundation

/// Claude Code's stream-json protocol, which a session Software Factory runs speaks over its standard
/// input and output, one JSON object a line, as Claude Desktop's do (`claude -p --input-format
/// stream-json --output-format stream-json --permission-prompt-tool stdio`).
///
/// - Out: `system` (`init` says the session and model), `assistant` (Claude's words and tool calls),
///   `user` (tool results, and what you wrote, replayed), `result` (the turn's end), and
///   `control_request` (`can_use_tool`, a permission prompt) and `control_cancel_request` (a prompt
///   settled some other way).
/// - In: `user` (what you write), `control_response` (a prompt's answer), and `control_request`
///   (`interrupt`, to stop the turn).
enum StreamJSON {
    /// What one line of output says.
    enum Output {
        case started(session: String, model: String?)
        case items([ChatItem])
        /// Tool calls' results: the tool call's id, and whether it failed, with what it said.
        case toolResults([(id: String, failed: Bool, output: String?)])
        /// The turn ended: how long it took, and its error when it failed.
        case finished(duration: TimeInterval?, error: String?)
        case permission(request: String, tool: String, input: [String: Any])
        case cancelled(request: String)
        case other
    }

    static func parse(_ line: Data, now: Date = .now) -> Output {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return .other }
        switch message["type"] as? String {
        case "system":
            guard message["subtype"] as? String == "init", let session = message["session_id"] as? String else { return .other }
            return .started(session: session, model: message["model"] as? String)
        case "assistant":
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            // Claude Code sends a reply's blocks as messages of their own, each with its own uuid.
            let id = message["uuid"] as? String ?? (message["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
            let items = content.enumerated().compactMap { index, block -> ChatItem? in
                switch block["type"] as? String {
                case "text":
                    guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                    return ChatItem(id: "\(id).\(index)", kind: .assistant, text: text, date: now)
                case "tool_use":
                    let tool = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    return ChatItem(id: block["id"] as? String ?? "\(id).\(index)", kind: .tool, text: HookText.activity(tool: tool, input: input),
                                    detail: toolDetail(tool: tool, input: input), date: now)
                default:
                    return nil
                }
            }
            return items.isEmpty ? .other : .items(items)
        case "user":
            let body = message["message"] as? [String: Any] ?? [:]
            if let blocks = body["content"] as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                return .toolResults(blocks.compactMap { block in
                    guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                    let failed = block["is_error"] as? Bool == true
                    return (id, failed, failed ? text(of: block["content"]) : nil)
                })
            }
            // What you wrote, replayed: without what the app adds in tags (reminders, hook output).
            guard message["isSynthetic"] as? Bool != true, message["isMeta"] as? Bool != true,
                  let text = text(of: body["content"]).map(HookText.userText(in:))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return .other }
            return .items([ChatItem(id: message["uuid"] as? String ?? UUID().uuidString, kind: .user, text: text, date: now)])
        case "result":
            let failed = message["is_error"] as? Bool == true || (message["subtype"] as? String).map { $0 != "success" } == true
            let error = failed ? (message["result"] as? String ?? (message["errors"] as? [String])?.first ?? String(localized: "The turn ended on an error")) : nil
            return .finished(duration: (message["duration_ms"] as? Double).map { $0 / 1000 }, error: error)
        case "control_request":
            let request = message["request"] as? [String: Any] ?? [:]
            guard request["subtype"] as? String == "can_use_tool", let id = message["request_id"] as? String,
                  let tool = request["tool_name"] as? String else { return .other }
            return .permission(request: id, tool: tool, input: request["input"] as? [String: Any] ?? [:])
        case "control_cancel_request":
            return (message["request_id"] as? String).map { .cancelled(request: $0) } ?? .other
        default:
            return .other
        }
    }

    /// A tool call's command, file or address, in full, under its few words.
    static func toolDetail(tool: String, input: [String: Any]) -> String? {
        let detail = input["command"] as? String ?? input["file_path"] as? String ?? input["url"] as? String
            ?? input["pattern"] as? String ?? input["query"] as? String ?? input["description"] as? String
        return detail.map { $0.hasPrefix(ProjectPath.home + "/") ? "~" + $0.dropFirst(ProjectPath.home.count) : $0 }
    }

    /// The text in a message's content: a string, or text blocks.
    static func text(of content: Any?) -> String? {
        if let text = content as? String { return text }
        let blocks = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n")
    }

    // MARK: - In

    /// What you write, as Claude Code reads it.
    static func userMessage(_ text: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull()])
    }

    /// A permission prompt's answer. Allowing hands back the tool's input, with a question's answers in it.
    static func answer(_ request: String, allow: Bool, input: [String: Any], answers: [String: String]? = nil, from: String) -> Data {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if allow {
            var updated = input
            if let answers { updated["answers"] = answers }
            decision["updatedInput"] = updated
        } else {
            decision["message"] = "The user denied this in Software Factory, on \(from)."
        }
        return line(["type": "control_response", "response": ["subtype": "success", "request_id": request, "response": decision]])
    }

    /// Changes how much the session asks before acting, from its next tool call on.
    static func setMode(_ mode: ChatMode, request: String = UUID().uuidString) -> Data {
        line(["type": "control_request", "request_id": request, "request": ["subtype": "set_permission_mode", "mode": mode.rawValue]])
    }

    /// Stops the turn under way.
    static func interrupt(_ request: String = UUID().uuidString) -> Data {
        line(["type": "control_request", "request_id": request, "request": ["subtype": "interrupt"]])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
