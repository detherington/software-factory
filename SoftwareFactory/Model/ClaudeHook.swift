import Foundation

/// Claude Code's hooks, read as session status. Each hook posts its JSON input unchanged to
/// `POST /api/hooks/claude`; this turns the events into a session's state, task, activity and
/// checklist:
///
/// - UserPromptSubmit: working, and the prompt's first line becomes the task.
/// - PreToolUse for AskUserQuestion or ExitPlanMode, and a permission Notification: needs you.
/// - PostToolUse: working again, with what it just did; TodoWrite and plan updates become steps.
/// - Stop: idle, its turn finished. SessionEnd: the session goes.
extension ProjectStore {
    /// `machine` names the other Mac it came from; nil for this one.
    @discardableResult
    func applyClaudeHook(_ payload: [String: Any], machine: String? = nil) -> Project? {
        guard let event = payload["hook_event_name"] as? String,
              let cwd = payload["cwd"] as? String,
              let sessionID = payload["session_id"] as? String,
              let id = projectID(forPath: cwd, create: true, machine: machine) else { return nil }
        let now = Date.now
        // A session new to the board may be a Claude Desktop chat: find it, to link to it.
        if machine == nil, chatsBySession[sessionID] == nil, chatLookups[sessionID, default: 0] < 3 {
            chatLookups[sessionID, default: 0] += 1
            refreshDesktopChats(after: .seconds(2))
        }

        return update(id) { p in
            let earlier = Set(p.events.map(\.id))
            defer {
                for index in p.events.indices where !earlier.contains(p.events[index].id) { p.events[index].machine = machine }
            }
            var s = p.sessions.first { $0.id == sessionID }
                ?? Session(id: sessionID, state: .idle, worktree: ProjectPath.worktree(in: cwd), machine: machine,
                           steps: [], started: now, updated: now, since: now)
            func set(_ state: ProjectState) {
                if s.state != state { s.state = state; s.since = now }
            }
            let tool = payload["tool_name"] as? String ?? ""
            let input = payload["tool_input"] as? [String: Any] ?? [:]

            switch event {
            case "SessionStart":
                // A compaction carries on mid-task; anything else starts fresh.
                if payload["source"] as? String != "compact" { set(.idle) }

            case "UserPromptSubmit":
                set(.working)
                s.message = nil
                if let task = HookText.task(from: payload["prompt"] as? String ?? ""), task != s.task {
                    // Short replies ("yes", "go ahead") carry on the task before them.
                    if s.task == nil || task.split(separator: " ").count >= 3 {
                        s.task = task
                        p.log(Event(date: now, state: .working, symbol: ProjectState.working.symbol, title: task,
                                    detail: s.worktree.map { "Started in \($0)" } ?? "Started"))
                    }
                }

            case "PreToolUse":
                if let message = HookText.waitingMessage(tool: tool, input: input) {
                    set(.waiting)
                    s.message = message
                    p.log(Event(date: now, state: .waiting, symbol: ProjectState.waiting.symbol, title: message, detail: s.task))
                }

            case "PostToolUse":
                set(.working)
                s.message = nil
                s.activity = HookText.activity(tool: tool, input: input)
                HookText.applySteps(tool: tool, input: input, to: &s.steps)

            case "Notification":
                let message = payload["message"] as? String ?? ""
                let type = payload["notification_type"] as? String ?? ""
                let needsYou = type == "permission_prompt" || type == "elicitation_dialog"
                    || (type.isEmpty && message.localizedCaseInsensitiveContains("permission"))
                if needsYou {
                    set(.waiting)
                    s.message = message.isEmpty ? "Waiting for your permission" : message
                    p.log(Event(date: now, state: .waiting, symbol: ProjectState.waiting.symbol, title: s.message!, detail: s.task))
                }

            case "Stop":
                let elapsed = now.timeIntervalSince(s.since)
                if s.state == .working {
                    p.log(Event(date: now, symbol: "checkmark.circle.fill", title: s.task ?? "Finished a turn",
                                detail: "Finished after \(Formats.duration(elapsed))"))
                }
                set(.idle)
                s.message = nil
                // A report of "working" ends with the turn, unless the project says otherwise.
                if p.reported == .working { p.reported = .idle; p.reportedAt = now }

            case "SessionEnd":
                p.sessions.removeAll { $0.id == sessionID }
                if p.sessions.isEmpty, p.reported == .working { p.reported = .idle; p.reportedAt = now }
                p.lastActivity = now
                return

            default:
                break
            }

            s.updated = now
            if let index = p.sessions.firstIndex(where: { $0.id == sessionID }) {
                p.sessions[index] = s
            } else {
                p.sessions.append(s)
            }
            // A dozen at most: the newest.
            if p.sessions.count > 12 {
                p.sessions.sort { $0.updated > $1.updated }
                p.sessions.removeLast(p.sessions.count - 12)
            }
            p.lastActivity = now
        }
    }
}

/// Words for hook events.
nonisolated enum HookText {
    /// The first meaningful line of a prompt, trimmed to a task-sized line.
    static func task(from prompt: String) -> String? {
        let line = prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("<") }
        guard let line else { return nil }
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let capitalized = collapsed.prefix(1).uppercased() + collapsed.dropFirst()
        return capitalized.count > 120 ? String(capitalized.prefix(117)) + "…" : capitalized
    }

    /// Why a tool stops for you, or nil if it doesn't.
    static func waitingMessage(tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return first ?? "Claude has a question"
        case "ExitPlanMode":
            return "A plan is ready for your review"
        default:
            return nil
        }
    }

    /// What a tool call did, in a few words: "Editing Theme.swift".
    static func activity(tool: String, input: [String: Any]) -> String {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing \(file ?? "a file")"
        case "Write": return "Writing \(file ?? "a file")"
        case "Read": return "Reading \(file ?? "a file")"
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty { return description }
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return "Running \(command.count > 48 ? String(command.prefix(47)) + "…" : command)"
        case "Grep", "Glob": return "Searching the code"
        case "WebSearch": return "Searching the web"
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host() }
            return "Reading \(host ?? "a web page")"
        case "Task", "Agent":
            return (input["description"] as? String).map { "Delegating: \($0)" } ?? "Delegating to an agent"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updating its plan"
        default:
            if tool.hasSuffix("update_plan") { return "Updating its plan" }
            if tool.hasPrefix("mcp__") {
                let name = tool.split(separator: "_", omittingEmptySubsequences: true).last.map(String.init) ?? tool
                return "Using \(name.replacingOccurrences(of: "-", with: " "))"
            }
            return "Using \(tool)"
        }
    }

    /// Task lists become the session's steps: TodoWrite, the desktop app's update_plan, TaskCreate/TaskUpdate.
    static func applySteps(tool: String, input: [String: Any], to steps: inout [Step]) {
        if tool == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
            steps = todos.map { Step(title: $0["content"] as? String ?? "", status: .init(loose: $0["status"] as? String)) }
        } else if tool.hasSuffix("update_plan") {
            if let items = input["items"] as? [[String: Any]] {
                steps = items.map { Step(title: $0["content"] as? String ?? "", status: .init(loose: $0["status"] as? String)) }
            }
            if input["advance"] as? Bool == true, let current = steps.firstIndex(where: { $0.status == .active }) {
                steps[current].status = .done
                if let next = steps[current...].firstIndex(where: { $0.status == .todo }) { steps[next].status = .active }
            }
            for number in input["done"] as? [Int] ?? [] where steps.indices.contains(number - 1) {
                steps[number - 1].status = .done
            }
            if let start = input["start"] as? Int, steps.indices.contains(start - 1) {
                for i in steps.indices where steps[i].status == .active { steps[i].status = .todo }
                steps[start - 1].status = .active
            }
        } else if tool == "TaskCreate", let subject = input["subject"] as? String {
            steps.append(Step(title: subject, status: .todo))
        } else if tool == "TaskUpdate", let raw = input["taskId"], let number = Int("\(raw)"), steps.indices.contains(number - 1) {
            if let status = input["status"] as? String { steps[number - 1].status = .init(loose: status) }
        }
    }
}
