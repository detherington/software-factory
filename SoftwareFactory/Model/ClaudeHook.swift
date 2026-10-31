import Foundation

/// Claude Code's hooks, read as session status. Each hook posts its JSON input unchanged to
/// `POST /api/hooks/claude`; this turns the events into a session's state, task, activity and
/// checklist:
///
/// - UserPromptSubmit: working, and the first line the user wrote becomes the task. Turns the app
///   starts (a linked session's news, a background task's result) keep the task they had.
/// - PreToolUse for AskUserQuestion or ExitPlanMode, PermissionRequest, and a permission Notification:
///   needs you. A PermissionRequest the board can answer becomes the session's `permission`.
/// - PostToolUse: working again, with what it just did; TodoWrite and plan updates become steps.
/// - StopFailure: the turn ended on an API error, so the session is blocked, with the error in words.
/// - Stop: idle, its turn finished; or Background, while work it started (a background command, an
///   async agent, a monitor, a scheduled wake-up) hasn't reported back. SessionEnd: the session goes.
extension ProjectStore {
    /// `machine` names the other Mac it came from; nil for this one. `permissionUntil`, for a
    /// PermissionRequest, is how long its hook waits for an answer from the board.
    @discardableResult
    func applyClaudeHook(_ payload: [String: Any], machine: String? = nil, permissionUntil: Date? = nil) -> Project? {
        guard let event = payload["hook_event_name"] as? String,
              let cwd = payload["cwd"] as? String,
              let sessionID = payload["session_id"] as? String else { return nil }
        // Another Mac's folders can't be looked at from here: its factory command says which
        // repository and worktree the session is in.
        let checkout = machine == nil ? nil : payload["factory_root"] as? String
        guard let id = projectID(forPath: checkout ?? cwd, create: true, machine: machine) else { return nil }
        let worktree = checkout != nil ? payload["factory_worktree"] as? String
            : machine == nil ? ProjectPath.worktree(in: cwd) : ProjectPath.namedWorktree(in: cwd)
        let now = Date.now
        // A session new to the board may be a Claude Desktop chat: find it, to link to it.
        if machine == nil, chatsBySession[sessionID] == nil, chatLookups[sessionID, default: 0] < 3 {
            chatLookups[sessionID, default: 0] += 1
            refreshDesktopChats(after: .seconds(2))
        } else if machine == nil, event == "Stop" || event == "Notification" {
            // When a turn ends or asks is when its chat's Remote Control link matters: read it again.
            refreshDesktopChats(after: .seconds(2))
        }

        return update(id) { p in
            let earlier = Set(p.events.map(\.id))
            defer {
                for index in p.events.indices where !earlier.contains(p.events[index].id) { p.events[index].machine = machine }
            }
            var s = p.sessions.first { $0.id == sessionID }
                ?? Session(id: sessionID, state: .idle, machine: machine, steps: [], started: now, updated: now, since: now)
            // EnterWorktree moves a session into a worktree, and ExitWorktree back out.
            s.worktree = worktree
            func set(_ state: ProjectState) {
                if s.state != state { s.state = state; s.since = now }
            }
            if machine == nil, let transcript = payload["transcript_path"] as? String { s.transcript = transcript }
            if let mode = payload["permission_mode"] as? String { s.planMode = mode == "plan" }
            let tool = payload["tool_name"] as? String ?? ""
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            // A prompt the board could answer is settled once the session moves on: the tool ran,
            // another prompt came, or the turn ended. A hook still waiting on it stops.
            if let ask = s.permission, HookText.settles(ask, event: event, tool: tool, input: input) {
                PermissionDesk.shared.settle(ask.id, with: nil)
                s.permission = nil
            }
            // A reply waiting for you is done with once the session moves on without it: you wrote
            // in Claude, or its process started again or stopped (and the hook with it). A compaction
            // while it waits leaves the hook be.
            if s.replyUntil != nil, ["UserPromptSubmit", "SessionStart", "SessionEnd"].contains(event),
               payload["source"] as? String != "compact" {
                PermissionDesk.shared.settleReply(sessionID, with: nil)
                s.replyUntil = nil
            }

            switch event {
            case "SessionStart":
                switch payload["source"] as? String {
                case "compact":
                    // A compaction carries on mid-task.
                    s.action = nil
                    s.activity = nil
                case "resume":
                    // Claude Desktop starts a session's process again when you open its chat: the
                    // question its turn ended with still waits for you. Anything else stopped with it.
                    if s.ask == nil || !s.state.needsYou { set(.idle) }
                    s.action = nil
                    s.activity = nil
                default:
                    set(.idle)
                    s.ask = nil
                    s.askBlocks = nil
                    s.askOptions = nil
                }

            case "UserPromptSubmit":
                set(.working)
                s.message = nil
                s.action = nil
                s.ask = nil
                s.askBlocks = nil
                s.askOptions = nil
                let prompt = payload["prompt"] as? String ?? ""
                // Background work that reported back has ended; so has a wake-up that's now firing.
                let ended = HookText.endedTasks(in: prompt)
                s.background?.removeAll { ended.contains($0.id) || ($0.kind == .wakeup && ($0.until ?? .distantFuture) <= now.addingTimeInterval(30)) }
                if prompt.contains(PermissionDesk.replyMarker) {
                    // Your reply from the board or the iPhone woke it: logged as you sent it.
                    s.appTurn = false
                    s.activity = nil
                } else if let task = HookText.task(from: prompt) {
                    s.appTurn = false
                    s.activity = nil
                    // A blocked report waits for you: your next word to the project, in any of its
                    // sessions, means it carries on, as a working report ends with its turn.
                    if p.reported == .blocked { p.reported = .idle; p.reportedAt = now; p.lastReport = now }
                    // Short replies ("yes", "go ahead") carry on the task before them; a slash command is new work.
                    if task != s.task, s.task == nil || task.hasPrefix("/") || task.split(separator: " ").count >= 3 {
                        s.task = task
                        p.log(Event(date: now, state: .working, symbol: ProjectState.working.symbol, title: task,
                                    detail: s.worktree.map { "Started in \($0)" } ?? "Started"))
                    }
                } else {
                    // The app woke it, with none of the user's words: the task stands, and the
                    // activity line says why it's working.
                    s.appTurn = true
                    s.activity = HookText.wake(from: prompt)
                }

            case "PreToolUse":
                // A command about to run: say what it is while it runs, not after.
                if tool == "Bash" {
                    set(.working)
                    s.activity = HookText.activity(tool: tool, input: input)
                    s.action = HookText.mode(of: input)
                }
                if let message = HookText.waitingMessage(tool: tool, input: input) {
                    set(.waiting)
                    s.message = message
                    p.log(Event(date: now, state: .waiting, symbol: ProjectState.waiting.symbol, title: message, detail: s.task))
                }

            case "PostToolUse":
                set(.working)
                s.message = nil
                s.action = nil
                if tool == "EnterPlanMode" { s.planMode = true }
                s.activity = HookText.activity(tool: tool, input: input)
                let before = s.steps
                HookText.applySteps(tool: tool, input: input, to: &s.steps)
                if s.steps != before { s.stepsUpdated = now }
                if let job = HookText.backgroundJob(tool: tool, input: input, response: payload["tool_response"], now: now) {
                    s.background = (s.background ?? []).filter { $0.id != job.id } + [job]
                }
                if tool == "TaskStop" || tool == "KillShell", let id = (input["task_id"] ?? input["shell_id"]) as? String {
                    s.background?.removeAll { $0.id == id }
                }
                // Claude Desktop's next-step box: the turn is ending, maybe with a question for you.
                if tool.hasSuffix("wrap_up") {
                    s.ask = (input["ask"] as? String)?.trimmed
                    s.askBlocks = input["blocked"] as? Bool
                    s.askOptions = s.ask == nil ? nil : HookText.replies(in: input)
                }

            case "PermissionRequest":
                // Plans come by PreToolUse, in their own words; so do questions, which the board can
                // answer while the hook waits.
                guard tool != "ExitPlanMode" else { break }
                if tool == "AskUserQuestion" {
                    guard let until = permissionUntil, let questions = HookText.questions(in: input) else { break }
                    s.permission = PermissionAsk(id: UUID().uuidString, tool: tool, summary: questions[0].question, asked: now,
                                                 until: until, questions: questions)
                    break
                }
                let words = HookText.permission(tool: tool, input: input)
                set(.waiting)
                s.message = words.message
                s.action = nil
                s.permission = permissionUntil.map {
                    PermissionAsk(id: UUID().uuidString, tool: tool, summary: words.summary, detail: words.detail, asked: now, until: $0)
                }
                p.log(Event(date: now, state: .waiting, symbol: ProjectState.waiting.symbol, title: words.message, detail: words.summary))

            case "Notification":
                let message = payload["message"] as? String ?? ""
                let type = payload["notification_type"] as? String ?? ""
                let needsYou = type == "permission_prompt" || type == "elicitation_dialog"
                    || (type.isEmpty && message.localizedCaseInsensitiveContains("permission"))
                // Six seconds into a prompt the PermissionRequest hook already put in words, it adds nothing.
                if needsYou, s.state != .waiting || s.message == nil {
                    set(.waiting)
                    s.message = message.isEmpty ? "Waiting for your permission" : message
                    p.log(Event(date: now, state: .waiting, symbol: ProjectState.waiting.symbol, title: s.message!, detail: s.task))
                }

            case "PreCompact":
                s.action = .compacting
                s.activity = String(localized: "Compacting the conversation")

            case "PostCompact":
                s.action = nil
                s.activity = nil

            case "StopFailure":
                // The turn ended on an API error: the transcript has it in words, or the hook does.
                s.action = nil
                let fromTranscript: String? = if machine == nil, case .apiError(let error) = s.transcript.flatMap(TranscriptScan.ending(of:)) { error } else { nil }
                let error = fromTranscript
                    ?? (payload["error"] as? String ?? payload["message"] as? String).map(TranscriptScan.errorText)
                    ?? String(localized: "Stopped on an API error")
                set(.blocked)
                s.message = error
                p.log(Event(date: now, state: .blocked, symbol: ProjectState.blocked.symbol, title: error, detail: s.task))

            case "Stop":
                s.action = nil
                let elapsed = now.timeIntervalSince(s.since)
                // The transcript has what the hooks missed: work started while the board was down, or
                // a notification that never reached it.
                if machine == nil, let transcript = s.transcript, let scan = TranscriptScan.scan(transcript, now: now) {
                    s.background = TranscriptScan.merge(s.background ?? [], with: scan, at: now)
                } else {
                    s.background = s.pendingJobs(at: now)
                }
                let waitingOn = s.jobsSummary(at: now)
                let ending = machine == nil ? s.transcript.flatMap(TranscriptScan.ending(of:)) : nil
                let finished = s.state == .working
                if case .apiError(let error) = ending {
                    // It stopped on an error, not by finishing.
                    set(.blocked)
                    s.message = error
                    p.log(Event(date: now, state: .blocked, symbol: ProjectState.blocked.symbol, title: error, detail: s.task))
                } else if let ask = s.ask {
                    // It finished with a question: blocking ones need you; the rest are your call.
                    let state: ProjectState = s.askBlocks == true ? .waiting : .yourCall
                    set(state)
                    s.message = ask
                    p.log(Event(date: now, state: state, symbol: state.symbol, title: ask,
                                detail: [s.task, "after \(Formats.duration(elapsed))"].compactMap { $0 }.joined(separator: " · ")))
                } else {
                    if finished, s.appTurn != true {
                        p.log(Event(date: now, symbol: "checkmark.circle.fill", title: s.task ?? "Finished a turn",
                                    detail: "Finished after \(Formats.duration(elapsed))" + (waitingOn.map { "; waiting on \($0)" } ?? "")))
                    }
                    set(waitingOn == nil ? .idle : .background)
                    s.message = nil
                }
                // A report of "working" ends with the turn, unless the project says otherwise.
                if p.reported == .working { p.reported = .idle; p.reportedAt = now; p.lastReport = now }

            case "SessionEnd":
                // Claude Desktop stops a chat's process while it waits for you, and starts it again
                // when you open the chat: a question its turn ended with still waits for you then. A
                // /clear, or anything else, ends with the process.
                if payload["reason"] as? String != "clear", s.ask != nil, s.state.needsYou,
                   p.sessions.contains(where: { $0.id == sessionID }) {
                    s.background = nil
                    s.action = nil
                    break
                }
                p.sessions.removeAll { $0.id == sessionID }
                if p.sessions.isEmpty, p.reported == .working { p.reported = .idle; p.reportedAt = now; p.lastReport = now }
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
    /// The first line the user wrote, trimmed to a task-sized line; nil when the app wrote all of it.
    static func task(from prompt: String) -> String? {
        // Slash commands arrive as tags: "<command-name>/compact</command-name>…<command-args>…</command-args>".
        if let name = prompt.firstMatch(of: /<command-name>\s*([^<]+?)\s*<\/command-name>/)?.1 {
            let args = prompt.firstMatch(of: /<command-args>([^<]*)<\/command-args>/)?.1 ?? ""
            return firstLine(of: "\(name) \(args)")
        }
        return firstLine(of: userText(in: prompt))
    }

    /// A prompt without the blocks the app adds to it, in tags: reminders and status notes, background
    /// task results, command output. A paste is the user's own, so it keeps what's inside.
    static func userText(in prompt: String) -> String {
        prompt
            .replacing(/<\/?pasted_content[^>]*>/, with: "")
            .replacing(/<([A-Za-z][\w-]*)[^>]*>[\s\S]*?<\/\1>/, with: "")
    }

    /// Why the app woke a session, in words, for a prompt with none of the user's.
    static func wake(from prompt: String) -> String {
        if let title = prompt.firstMatch(of: /The session "([^"]+)" you started/)?.1 {
            return String(localized: "Hearing back from “\(String(title))”")
        }
        if prompt.contains("Linked sessions now") { return String(localized: "Checking on its linked sessions") }
        if prompt.contains("<task-notification") { return String(localized: "Reading a background task's result") }
        return String(localized: "Picking up an update from the app")
    }

    /// What a command is for, from its description (Claude's words) or else the command itself:
    /// shipping (TestFlight, deploys, uploads), testing (tests, smoke runs, checks), building.
    static func mode(of input: [String: Any]) -> WorkMode? {
        let description = (input["description"] as? String ?? "").lowercased()
        let command = (input["command"] as? String ?? "").lowercased()
        for text in [description, command] where !text.isEmpty {
            if text.contains(/testflight|altool|notarytool|notariz|deploy|publish|upload|fastlane|app store|wrangler (deploy|publish)|vercel --prod/) { return .shipping }
            if text.contains(/\btests?\b|\btesting\b|xcodebuild[^|;&]*\btest\b|pytest|jest|vitest|rspec|smoke|\bchecks?\b/) { return .testing }
            if text.contains(/\bbuild(s|ing)?\b|xcodebuild|swift build|\barchive|compil|\bmake\b|\btsc\b|webpack|gradle/) { return .building }
        }
        return nil
    }

    /// Work a tool call started to come back to, from its result: a background command's
    /// `backgroundTaskId`, an async agent's `agentId`, a monitor's `taskId` and timeout, a wake-up's time.
    static func backgroundJob(tool: String, input: [String: Any], response: Any?, now: Date) -> BackgroundJob? {
        let result = response as? [String: Any] ?? [:]
        // Only a result that's plain text is read for its wording: a structured one says it all, and
        // its output can quote anything (another job's "running in background with ID").
        let text = response as? String ?? ""
        func describe(_ fallback: String) -> String {
            if let description = (input["description"] as? String)?.trimmed { return description }
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return command.isEmpty ? fallback : (command.count > 60 ? String(command.prefix(59)) + "…" : command)
        }
        switch tool {
        case "Bash":
            guard input["run_in_background"] as? Bool == true else { return nil }
            let id = result["backgroundTaskId"] as? String
                ?? text.firstMatch(of: /background with ID: ([A-Za-z0-9_-]+)/).map { String($0.1) }
            return id.map { BackgroundJob(id: $0, kind: .command, title: describe(String(localized: "A background command")), started: now) }
        case "Agent", "Task":
            guard result["isAsync"] as? Bool == true || text.contains("Async agent launched") else { return nil }
            let id = result["agentId"] as? String ?? text.firstMatch(of: /agentId: ([A-Za-z0-9_-]+)/).map { String($0.1) }
            return id.map { BackgroundJob(id: $0, kind: .agent, title: describe(String(localized: "A background agent")), started: now) }
        case "Monitor":
            let id = result["taskId"] as? String ?? text.firstMatch(of: /Monitor started \(task ([A-Za-z0-9_-]+)/).map { String($0.1) }
            let timeout = (result["timeoutMs"] as? Double).map { now.addingTimeInterval($0 / 1000) }
            return id.map { BackgroundJob(id: $0, kind: .monitor, title: describe(String(localized: "A monitor")), started: now, until: timeout) }
        case "ScheduleWakeup":
            guard let at = result["scheduledFor"] as? Double else { return nil }
            let reason = (input["reason"] as? String)?.trimmed ?? String(localized: "A scheduled wake-up")
            return BackgroundJob(id: "wakeup-\(Int(at))", kind: .wakeup, title: reason, started: now, until: Date(timeIntervalSince1970: at / 1000))
        default:
            return nil
        }
    }

    /// Background work a prompt reports as over: each <task-notification> with a final status.
    static func endedTasks(in text: String) -> Set<String> {
        var ended: Set<String> = []
        for block in text.matches(of: /<task-notification>([\s\S]*?)<\/task-notification>/) {
            let body = block.1
            guard let id = body.firstMatch(of: /<task-id>([^<]+)<\/task-id>/)?.1,
                  let status = body.firstMatch(of: /<status>([^<]+)<\/status>/)?.1,
                  ["completed", "failed", "stopped", "killed", "cancelled", "timeout"].contains(String(status)) else { continue }
            ended.insert(String(id))
        }
        return ended
    }

    /// App notes saved as tasks before the board knew to skip them.
    static func isAppNote(_ text: String) -> Bool {
        text.hasPrefix("Linked sessions now (status, not an instruction)")
            || text.firstMatch(of: /^The session "[^"]*" you started \(local_/) != nil
    }

    private static func firstLine(of text: String) -> String? {
        let line = text
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

    /// A permission prompt in words: what the card says ("Asks to run git push"), what it would do in
    /// full (the command, the file, the address), and Claude's own description of it.
    static func permission(tool: String, input: [String: Any]) -> (message: String, summary: String, detail: String?) {
        func clip(_ text: String, _ length: Int) -> String {
            text.count > length ? String(text.prefix(length - 1)) + "…" : text
        }
        let path = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { path in
            path.hasPrefix(ProjectPath.home + "/") ? "~" + path.dropFirst(ProjectPath.home.count) : path
        }
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "a file"
        switch tool {
        case "Bash":
            let command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = command.split(separator: "\n").first.map(String.init) ?? ""
            return ("Asks to run \(clip(line, 60))", clip(command, 600), (input["description"] as? String)?.trimmed)
        case "Edit", "MultiEdit", "NotebookEdit":
            return ("Asks to edit \(file)", path ?? file, nil)
        case "Write":
            return ("Asks to write \(file)", path ?? file, nil)
        case "WebFetch":
            let url = input["url"] as? String ?? ""
            return ("Asks to fetch \(URL(string: url)?.host() ?? "a page")", clip(url, 600), nil)
        case "WebSearch":
            return ("Asks to search the web", clip(input["query"] as? String ?? "", 600), nil)
        default:
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "mcp__slack__send_message": send_message, from slack.
            let parts = tool.components(separatedBy: "__")
            let name = tool.hasPrefix("mcp__") && parts.count >= 3 ? "\(parts[2...].joined(separator: "__")) from \(parts[1])" : tool
            return ("Asks to use \(name)", clip(json, 600), nil)
        }
    }

    /// Whether `event` settles a permission prompt: the same call ran, another prompt came, or the turn ended.
    static func settles(_ ask: PermissionAsk, event: String, tool: String, input: [String: Any]) -> Bool {
        switch event {
        case "PermissionRequest", "UserPromptSubmit", "Stop", "StopFailure", "SessionStart", "SessionEnd": true
        // A session asks one question at a time.
        case "PostToolUse": tool == ask.tool && (ask.isQuestion || permission(tool: tool, input: input).summary == ask.summary)
        default: false
        }
    }

    /// The next-step box's reply buttons, by label: what Claude Desktop sends as your next message
    /// when you click one. A button for one of the app's own actions (commit, create a PR) does that
    /// in the app instead, so it isn't one.
    static func replies(in input: [String: Any]) -> [String]? {
        let labels = (input["actions"] as? [[String: Any]] ?? []).compactMap { action -> String? in
            action["action"] == nil ? (action["label"] as? String)?.trimmed : nil
        }
        return labels.isEmpty ? nil : labels
    }

    /// AskUserQuestion's questions, with their options; nil if it has none the board can show.
    static func questions(in input: [String: Any]) -> [PermissionAsk.Question]? {
        let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { item -> PermissionAsk.Question? in
            guard let text = item["question"] as? String else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option in
                (option["label"] as? String).map { PermissionAsk.Question.Option(label: $0, description: option["description"] as? String) }
            }
            return PermissionAsk.Question(question: text, header: item["header"] as? String, options: options,
                                          multiSelect: item["multiSelect"] as? Bool ?? false)
        }
        return questions.isEmpty ? nil : questions
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
            if input["advance"] as? Bool == true { Step.advance(&steps) }
            for number in input["done"] as? [Int] ?? [] where steps.indices.contains(number - 1) {
                steps[number - 1].status = .done
            }
            if let start = input["start"] as? Int, steps.indices.contains(start - 1) {
                for i in steps.indices where steps[i].status == .active { steps[i].status = .todo }
                steps[start - 1].status = .active
            }
        } else if tool.hasSuffix("wrap_up") {
            // Claude Desktop's wrap-up ticks off the step under way.
            for index in steps.indices where steps[index].status == .active { steps[index].status = .done }
        } else if tool == "TaskCreate", let subject = input["subject"] as? String {
            steps.append(Step(title: subject, status: .todo))
        } else if tool == "TaskUpdate", let raw = input["taskId"], let number = Int("\(raw)"), steps.indices.contains(number - 1) {
            if let status = input["status"] as? String { steps[number - 1].status = .init(loose: status) }
        }
    }
}
