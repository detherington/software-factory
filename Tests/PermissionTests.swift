import Foundation
import Testing

/// Answering Claude Code's permission prompts from the board and the iPhone: the hook that waits,
/// what the board shows, and what it hands back to Claude Code.
@MainActor
@Suite("Permission prompts")
struct PermissionTests {
    let store = TestBoard.make()
    let desk = PermissionDesk.shared

    @discardableResult
    private func ask(_ session: String, command: String = "git push origin main", until: Date? = .now.addingTimeInterval(600)) -> Project? {
        store.hook("UserPromptSubmit", session, ["prompt": "Ship it"])
        return store.applyClaudeHook([
            "hook_event_name": "PermissionRequest", "session_id": session, "cwd": TestBoard.projectFolder,
            "tool_name": "Bash", "tool_input": ["command": command, "description": "Push to GitHub"],
        ], permissionUntil: until)
    }

    // MARK: - What the board shows

    @Test func aPromptIsPutInWords() {
        let bash = HookText.permission(tool: "Bash", input: ["command": "rm -rf build\nls", "description": "Clean the build"])
        #expect(bash.message == "Asks to run rm -rf build")
        #expect(bash.summary == "rm -rf build\nls")
        #expect(bash.detail == "Clean the build")
        let edit = HookText.permission(tool: "Edit", input: ["file_path": ProjectPath.home + "/Moth Radio/Theme.swift"])
        #expect(edit.message == "Asks to edit Theme.swift")
        #expect(edit.summary == "~/Moth Radio/Theme.swift")
        #expect(HookText.permission(tool: "WebFetch", input: ["url": "https://example.com/a"]).message == "Asks to fetch example.com")
        let mcp = HookText.permission(tool: "mcp__slack__send_message", input: ["text": "Hi"])
        #expect(mcp.message == "Asks to use send_message from slack")
        #expect(mcp.summary == #"{"text":"Hi"}"#)
    }

    @Test func aPromptMakesTheSessionWait() throws {
        let id = UUID().uuidString
        let project = try #require(ask(id))
        let session = try #require(project.sessions.first { $0.id == id })
        #expect(session.state == .waiting)
        #expect(session.message == "Asks to run git push origin main")
        #expect(session.permission?.summary == "git push origin main")
        #expect(session.permission?.detail == "Push to GitHub")
        #expect(project.openPermission(at: .now)?.session.id == id)
    }

    /// Without a hook waiting, the board says what's asked but can't answer it.
    @Test func aPromptNobodyWaitsOnHasNoButtons() {
        let id = UUID().uuidString
        ask(id, until: nil)
        #expect(store.session(id)?.state == .waiting)
        #expect(store.session(id)?.permission == nil)
    }

    /// Claude Code's own notification, six seconds in, adds nothing to a prompt the board has in words.
    @Test func theNotificationAfterwardChangesNothing() {
        let id = UUID().uuidString
        ask(id)
        let events = store[TestBoard.projectID]?.events.count
        store.hook("Notification", id, ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
        #expect(store.session(id)?.message == "Asks to run git push origin main")
        #expect(store[TestBoard.projectID]?.events.count == events)
        #expect(store.session(id)?.permission != nil)
    }

    /// Answered in Claude: the call runs, and the prompt leaves the board. Another tool doesn't settle it.
    @Test func aPromptIsSettledWhenItsCallRuns() {
        let id = UUID().uuidString
        ask(id)
        store.hook("PostToolUse", id, ["tool_name": "Read", "tool_input": ["file_path": "/x/README.md"]])
        #expect(store.session(id)?.permission != nil)
        store.hook("PostToolUse", id, ["tool_name": "Bash", "tool_input": ["command": "git push origin main"]])
        #expect(store.session(id)?.permission == nil)
    }

    @Test func aPromptIsSettledWhenTheTurnEnds() {
        let id = UUID().uuidString
        ask(id)
        store.hook("Stop", id)
        #expect(store.session(id)?.permission == nil)
    }

    @Test func promptsLeftFromBeforeALaunchAreDropped() {
        let id = UUID().uuidString
        ask(id)
        store.dropStalePermissions()
        #expect(store.session(id)?.permission == nil)
    }

    // MARK: - When the hook waits

    @Test func desktopAlwaysWaitsAndTerminalOnlyWhenYoureAway() {
        let wait = ClaudeSetup.permissionWait
        #expect(PermissionDesk.wait(tool: "Bash", entrypoint: "claude-desktop", away: false, isOn: true) == wait)
        #expect(PermissionDesk.wait(tool: "Bash", entrypoint: "sdk-ts", away: false, isOn: true) == wait)
        #expect(PermissionDesk.wait(tool: "Bash", entrypoint: "cli", away: false, isOn: true) == nil)
        #expect(PermissionDesk.wait(tool: "Bash", entrypoint: nil, away: false, isOn: true) == nil)
        #expect(PermissionDesk.wait(tool: "Bash", entrypoint: "cli", away: true, isOn: true) == wait)
        // Questions wait as permissions do; plans are reviewed in Claude; and the setting turns it all off.
        #expect(PermissionDesk.wait(tool: "AskUserQuestion", entrypoint: "claude-desktop", away: false, isOn: true) == ClaudeSetup.permissionWait)
        #expect(PermissionDesk.wait(tool: "ExitPlanMode", entrypoint: "claude-desktop", away: true, isOn: true) == nil)
        #expect(PermissionDesk.wait(tool: "Bash", entrypoint: "claude-desktop", away: true, isOn: false) == nil)
    }

    @Test func anAnswerReachesTheWaitingHook() async {
        let id = UUID().uuidString
        async let answer = desk.answer(for: id, until: .now.addingTimeInterval(60))
        #expect(await eventually { desk.isWaiting(for: id) })
        #expect(desk.settle(id, with: PermissionDesk.Answer(allow: true, from: "the iPhone")))
        #expect(await answer == PermissionDesk.Answer(allow: true, from: "the iPhone"))
        #expect(!desk.isWaiting(for: id))
    }

    @Test func aHookStopsWaitingWhenItsTimeIsUp() async {
        let answer = await desk.answer(for: UUID().uuidString, until: .now.addingTimeInterval(0.2))
        #expect(answer == nil)
    }

    /// The hook's connection closing (its prompt answered in Claude) cancels the wait.
    @Test func aHookThatGoesAwayStopsTheWait() async {
        let id = UUID().uuidString
        let wait = Task { await desk.answer(for: id, until: .now.addingTimeInterval(60)) }
        #expect(await eventually { desk.isWaiting(for: id) })
        wait.cancel()
        #expect(await wait.value == nil)
        #expect(!desk.isWaiting(for: id))
    }

    @Test func whatClaudeCodeIsTold() throws {
        let allow = try #require(JSONSerialization.jsonObject(with: PermissionDesk.decision(.init(allow: true, from: "this Mac"))) as? [String: Any])
        let output = try #require(allow["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        #expect((output["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        let deny = try #require(JSONSerialization.jsonObject(with: PermissionDesk.decision(.init(allow: false, from: "the iPhone"))) as? [String: Any])
        let decision = try #require((deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "The user denied this in Software Factory, on the iPhone.")
    }

    // MARK: - End to end

    /// The hook's request to the API waits; Allow on the board answers it with Claude Code's decision.
    @Test func theAPIHoldsTheHookUntilTheBoardAnswers() async throws {
        let id = UUID().uuidString
        store.hook("UserPromptSubmit", id, ["prompt": "Ship it"])
        let body = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": id, "cwd": TestBoard.projectFolder,
            "tool_name": "Bash", "tool_input": ["command": "git push origin main"],
        ])
        let request = HTTPRequest(method: "POST", path: "api/hooks/claude", query: [:],
                                  headers: ["host": "127.0.0.1:7720", "x-claude-entrypoint": "claude-desktop"], body: body)
        let response = API.handle(request, store: store)
        let later = try #require(response.later)
        let reply = Task { await later() }
        let ask = try #require(store.session(id)?.permission)
        #expect(await eventually { desk.isWaiting(for: ask.id) })

        #expect(store.answerPermission(ask.id, allow: true, from: "this Mac"))
        let replied = await reply.value
        let answer = try #require(JSONSerialization.jsonObject(with: replied.body) as? [String: Any])
        #expect(((answer["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        #expect(store.session(id)?.permission == nil)
        #expect(store.session(id)?.state == .working)
        #expect(store[TestBoard.projectID]?.events.first?.title == "Allowed on this Mac")
    }

    /// A Terminal session while you're at a Mac: the board shows the prompt and leaves it to Terminal.
    @Test func theAPILeavesATerminalPromptToTerminal() throws {
        let id = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": id, "cwd": TestBoard.projectFolder,
            "tool_name": "Bash", "tool_input": ["command": "make"],
        ])
        let request = HTTPRequest(method: "POST", path: "api/hooks/claude", query: [:],
                                  headers: ["host": "127.0.0.1:7720", "x-claude-entrypoint": "cli"], body: body)
        let response = API.handle(request, store: store)
        // Tests run at a Mac in use, unless nobody has touched it for five minutes.
        guard Date.now.timeIntervalSince(PhoneShare.shared.lastUsedAnyMac) < PhoneShare.awayAfter else { return }
        #expect(response.later == nil)
        #expect(response.body.isEmpty)
        #expect(store.session(id)?.state == .waiting)
    }

    @Test func theAPIAnswersAPromptByItsID() async throws {
        let id = UUID().uuidString
        ask(id)
        let ask = try #require(store.session(id)?.permission)
        let wait = Task { await desk.answer(for: ask.id, until: .now.addingTimeInterval(60)) }
        #expect(await eventually { desk.isWaiting(for: ask.id) })
        let request = HTTPRequest(method: "POST", path: "api/permissions/\(ask.id)", query: [:], headers: ["host": "127.0.0.1:7720"],
                                  body: Data(#"{"allow": false}"#.utf8))
        #expect(String(decoding: API.handle(request, store: store).body, as: UTF8.self).contains(#""answered":true"#))
        #expect(await wait.value == PermissionDesk.Answer(allow: false, from: "this Mac"))
    }

    // MARK: - From the iPhone

    @Test func theIPhonesAnswerReachesTheHook() async throws {
        let id = UUID().uuidString
        ask(id)
        let ask = try #require(store.session(id)?.permission)
        let wait = Task { await desk.answer(for: ask.id, until: .now.addingTimeInterval(60)) }
        #expect(await eventually { desk.isWaiting(for: ask.id) })
        let change = CloudBoard.Change(kind: .permission, project: TestBoard.projectID, permission: ask.id, allow: true, answered: .now)
        #expect(PhoneShare.fold(change, into: store, digests: DigestStore.shared))
        #expect(await wait.value == PermissionDesk.Answer(allow: true, from: "the iPhone"))
        #expect(store[TestBoard.projectID]?.events.first?.title == "Allowed on the iPhone")
    }

    /// One this Mac never had may be another Mac's: it stays in the inbox while a hook could wait on it.
    @Test func anAnswerForAnotherMacsPromptWaitsForIt() {
        let recent = CloudBoard.Change(kind: .permission, permission: UUID().uuidString, allow: true, answered: .now)
        #expect(!PhoneShare.fold(recent, into: store, digests: DigestStore.shared))
        let old = CloudBoard.Change(kind: .permission, permission: UUID().uuidString, allow: true, answered: .now.addingTimeInterval(-3600))
        #expect(PhoneShare.fold(old, into: store, digests: DigestStore.shared))
    }

    @Test func thePhoneGetsThePrompt() throws {
        let id = UUID().uuidString
        let project = try #require(ask(id))
        #expect(CloudBoard.phoneCopy(project).sessions.first { $0.id == id }?.permission?.summary == "git push origin main")
    }

    // MARK: - Notifications

    @Test func aPromptsNotificationSaysWhatItWouldDo() throws {
        let id = UUID().uuidString
        let project = try #require(ask(id))
        let session = try #require(project.sessions.first { $0.id == id })
        let alert = PermissionDesk.alert(for: try #require(session.permission), in: session, project: project)
        #expect(alert.title == "Moth Radio needs your permission")
        #expect(alert.body == "Push to GitHub\ngit push origin main")
    }

    /// Away from your Macs, a prompt goes to the iPhone at once; anything else that needs you after
    /// two minutes.
    @Test func aPromptAlertsTheIPhoneAtOnce() throws {
        let id = UUID().uuidString
        let project = try #require(ask(id))
        let alertID = PermissionAlert.recordName(for: try #require(project.sessions.first { $0.id == id }?.permission?.id))
        let now = Date.now
        #expect(PhoneShare.alertsDue(in: [project], now: now, sent: []).map(\.id) == [alertID])
        #expect(PhoneShare.alertsDue(in: [project], now: now, sent: [alertID]).isEmpty)
        var asking = project
        asking.sessions = asking.sessions.map { var session = $0; session.permission = nil; return session }
        #expect(PhoneShare.alertsDue(in: [asking], now: now, sent: []).isEmpty)
        #expect(PhoneShare.alertsDue(in: [asking], now: now.addingTimeInterval(PhoneShare.alertDelay + 1), sent: []).count == 1)
    }

    /// The iPhone's extension knows a prompt's alert by its record's name, as iCloud pushes it.
    @Test func anAlertKnowsItsPrompt() {
        #expect(PermissionAlert.ask(fromRecordName: PermissionAlert.recordName(for: "ABC")) == "ABC")
        #expect(PermissionAlert.ask(fromRecordName: "s1.waiting.1793300000") == nil)
        #expect(PermissionAlert.ask(in: [PermissionAlert.key: "ABC"]) == "ABC")
        let push: [AnyHashable: Any] = [
            "aps": ["mutable-content": 1, "alert": ["title": "Moth Radio needs your permission"]],
            "ck": ["ce": 2, "cid": "iCloud.com.darrell.softwarefactory", "nid": UUID().uuidString,
                   "qry": ["dbs": 1, "fo": 1, "rid": "permission.ABC", "sid": "alerts", "zid": "_defaultZone", "zoid": "_defaultOwner",
                           "af": ["project": "moth-radio"]]],
        ]
        #expect(PermissionAlert.ask(in: push) == "ABC")
        var other = push
        other["ck"] = ["ce": 2, "cid": "iCloud.com.darrell.softwarefactory", "nid": UUID().uuidString,
                       "qry": ["dbs": 1, "fo": 1, "rid": "s1.waiting.1793300000", "sid": "alerts", "zid": "_defaultZone", "zoid": "_defaultOwner"]]
        #expect(PermissionAlert.ask(in: other) == nil)
    }

    /// Alerts arrive changeable, so the extension can add the buttons.
    @Test func alertsCanBeGivenButtons() {
        #expect(CloudBoard.alertsSubscription().notificationInfo?.shouldSendMutableContent == true)
    }

    // MARK: - Installing the hook

    @Test func theHookIsInstalledToWait() throws {
        let hooks = ClaudeSetup.hooks([:], adding: ClaudeSetup.command(port: 7720))
        let entry = try #require((hooks["PermissionRequest"] as? [[String: Any]])?.first)
        let handler = try #require((entry["hooks"] as? [[String: Any]])?.first)
        #expect(entry["matcher"] as? String == "*")
        #expect(handler["command"] as? String == ClaudeSetup.permissionCommand(port: 7720))
        #expect(handler["timeout"] as? Int == Int(ClaudeSetup.permissionWait) + 60)
        let command = try #require(handler["command"] as? String)
        // It keeps the board's answer, and says which app runs Claude Code.
        #expect(!command.contains("/dev/null"))
        #expect(command.contains("X-Claude-Entrypoint: ${CLAUDE_CODE_ENTRYPOINT:-}"))
        #expect(ClaudeSetup.upgrade(for: hooks) == nil)
    }

    /// Hooks a version before this one installed get the PermissionRequest hook, with the same command.
    @Test func olderHooksAreBroughtUpToDate() {
        let command = ClaudeSetup.command(port: 7720)
        var hooks = ClaudeSetup.hooks([:], adding: command)
        hooks["PermissionRequest"] = nil
        #expect(ClaudeSetup.upgrade(for: hooks) == command)
        // Someone else's hooks are kept as they are.
        let theirs: [String: Any] = ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]
        #expect(ClaudeSetup.upgrade(for: theirs) == nil)
    }

    @Test func anotherMacsHookPrintsTheAnswer() {
        let path = "/Users/someone/Tools's/factory"
        let command = ClaudeSetup.command(factory: path)
        #expect(ClaudeSetup.permissionCommand(like: command) == ClaudeSetup.permissionCommand(factory: path))
        // Only errors go to /dev/null: the answer comes out.
        #expect(!ClaudeSetup.permissionCommand(factory: path).contains(" hook >/dev/null"))
        #expect(ClaudeSetup.command(factory: path).contains(" hook >/dev/null"))
    }

    // MARK: - Questions

    private let question = "Which way should the start screen go?"

    private var questionInput: [String: Any] {
        ["questions": [["question": question, "header": "Direction", "multiSelect": false,
                        "options": [["label": "Backdrop", "description": "The canvas behind everything"], ["label": "Grid"]]]]]
    }

    @discardableResult
    private func askQuestion(_ session: String) -> Project? {
        store.hook("UserPromptSubmit", session, ["prompt": "Redo the start screen"])
        store.hook("PreToolUse", session, ["tool_name": "AskUserQuestion", "tool_input": questionInput])
        return store.applyClaudeHook([
            "hook_event_name": "PermissionRequest", "session_id": session, "cwd": TestBoard.projectFolder,
            "tool_name": "AskUserQuestion", "tool_input": questionInput,
        ], permissionUntil: .now.addingTimeInterval(600))
    }

    @Test func aQuestionCanBeAnsweredFromTheBoard() throws {
        let id = UUID().uuidString
        askQuestion(id)
        let session = try #require(store.session(id))
        #expect(session.state == .waiting)
        #expect(session.message == question)
        let questions = try #require(session.permission?.questions)
        #expect(questions.first?.header == "Direction")
        #expect(questions.first?.options.map(\.label) == ["Backdrop", "Grid"])
        #expect(questions.first?.options.first?.description == "The canvas behind everything")

        // Answered in Claude: the question goes.
        store.hook("PostToolUse", id, ["tool_name": "AskUserQuestion", "tool_input": questionInput])
        #expect(store.session(id)?.permission == nil)
    }

    /// The answers go back inside the tool's input, as Claude Code takes them: Claude Desktop took
    /// one this way on 30 October.
    @Test func answersGoBackInTheToolsInput() throws {
        let input = try JSONSerialization.data(withJSONObject: questionInput)
        let answer = PermissionDesk.Answer(allow: true, from: "this Mac", answers: [question: "Grid"])
        let output = try #require(JSONSerialization.jsonObject(with: PermissionDesk.decision(answer, input: input)) as? [String: Any])
        let decision = try #require((output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        #expect((updated["questions"] as? [Any])?.count == 1)
        #expect((updated["answers"] as? [String: String])?[question] == "Grid")
    }

    @Test func whatYouPickAndTypeBecomesTheAnswer() {
        let one = PermissionAsk.Question(question: "One?", options: [.init(label: "A"), .init(label: "B")])
        let many = PermissionAsk.Question(question: "Many?", options: [.init(label: "A"), .init(label: "B"), .init(label: "C")], multiSelect: true)
        #expect(PermissionAsk.answer(to: one, chosen: ["B"], typed: "") == "B")
        #expect(PermissionAsk.answer(to: one, chosen: ["B"], typed: " Neither ") == "Neither")
        #expect(PermissionAsk.answer(to: one, chosen: [], typed: "") == nil)
        #expect(PermissionAsk.answer(to: many, chosen: ["C", "A"], typed: "") == "A, C")
        #expect(PermissionAsk.answer(to: many, chosen: ["B"], typed: "and D") == "B, and D")
    }

    @Test func answeringAQuestionLogsTheAnswer() throws {
        let id = UUID().uuidString
        askQuestion(id)
        let askID = try #require(store.session(id)?.permission?.id)
        // An older iPhone's Allow can't answer a question.
        #expect(!store.answerPermission(askID, reply: .allow, from: "the iPhone"))
        #expect(store.session(id)?.permission != nil)
        // Nothing waits in a test, but the answer still settles it on the board.
        store.answerPermission(askID, reply: .answers([question: "Grid"]), from: "the iPhone")
        #expect(store.session(id)?.permission == nil)
    }

    @Test func aQuestionsNotificationButtonsAnswerIt() throws {
        let id = UUID().uuidString
        askQuestion(id)
        let askID = try #require(store.session(id)?.permission?.id)
        #expect(Notifier.answers(action: "option.1", text: nil, to: askID, in: store) == [question: "Grid"])
        #expect(Notifier.answers(action: "reply", text: " Something else ", to: askID, in: store) == [question: "Something else"])
        #expect(Notifier.answers(action: "option.7", text: nil, to: askID, in: store) == nil)
        #expect(Notifier.answers(action: "open-chat", text: nil, to: askID, in: store) == nil)
    }

    /// On the iPhone a question's alert has no Allow or Deny: tapping it opens the project.
    @Test func aQuestionsAlertIsNamedForAQuestion() throws {
        let id = UUID().uuidString
        let project = try #require(askQuestion(id))
        let askID = try #require(store.session(id)?.permission?.id)
        let alerts = PhoneShare.alertsDue(in: [project], now: .now, sent: [])
        #expect(alerts.map(\.id) == [PermissionAlert.questionRecordName(for: askID)])
        #expect(alerts.first?.title == "Moth Radio asks")
        #expect(alerts.first?.body == "\(question)\nBackdrop · Grid")
        #expect(PermissionAlert.ask(fromRecordName: alerts[0].id) == nil)
    }
}
