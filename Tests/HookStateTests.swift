import Foundation
import Testing

/// Claude Code's hooks, in the order Claude Code and Claude Desktop send them, and the state a
/// session ends up in.
@MainActor
@Suite("Hooks to state")
struct HookStateTests {
    let store = TestBoard.make()
    let id = UUID().uuidString

    private func prompt(_ text: String) {
        store.hook("UserPromptSubmit", id, ["prompt": text])
    }

    /// Claude Desktop's next-step box: the turn is ending, maybe with a question.
    private func wrapUp(ask: String? = nil, blocked: Bool? = nil) {
        var input: [String: Any] = ["recap": "Done."]
        if let ask { input["ask"] = ask }
        if let blocked { input["blocked"] = blocked }
        store.hook("PostToolUse", id, ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": input])
    }

    /// `factory blocked` waits for you: your next prompt, in any of the project's sessions, means
    /// it carries on. Volt Crystal read Blocked for half an hour while its session worked again.
    @Test func aBlockedReportEndsWithYourNextPrompt() throws {
        prompt("Build the iOS player")
        let report = try JSONDecoder().decode(Report.self, from: Data(#"{"state": "blocked", "note": "Waiting on iOS Build Support"}"#.utf8))
        try store.apply(report, to: TestBoard.projectID)
        store.hook("Stop", id)
        #expect(store[TestBoard.projectID]?.state(at: .now) == .blocked)
        // The app waking the session with a background task's result isn't you.
        store.hook("UserPromptSubmit", id, ["prompt": "<task-notification><status>completed</status></task-notification>"])
        store.hook("Stop", id)
        #expect(store[TestBoard.projectID]?.state(at: .now) == .blocked)

        prompt("iOS Build Support is installed. Carry on with the task.")
        #expect(store[TestBoard.projectID]?.state(at: .now) == .working)
        store.hook("Stop", id)
        #expect(store[TestBoard.projectID]?.state(at: .now) == .idle)
    }

    @Test func aPromptIsWorkAndStopFinishesIt() {
        prompt("fix the page turn in the reader")
        #expect(store.session(id)?.state == .working)
        #expect(store.session(id)?.task == "Fix the page turn in the reader")

        store.hook("Stop", id)
        #expect(store.session(id)?.state == .idle)
        #expect(store[TestBoard.projectID]?.events.first?.title == "Fix the page turn in the reader")
        #expect(store[TestBoard.projectID]?.events.first?.symbol == "checkmark.circle.fill")
    }

    @Test func aShortReplyCarriesOnTheTask() {
        prompt("Fix the page turn in the reader")
        store.hook("Stop", id)
        prompt("yes")
        #expect(store.session(id)?.task == "Fix the page turn in the reader")
        prompt("/compact")
        #expect(store.session(id)?.task == "/compact")
    }

    @Test func aQuestionNeedsYou() {
        prompt("Pick an icon")
        store.hook("PreToolUse", id, ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Which icon?"]]]])
        #expect(store.session(id)?.state == .waiting)
        #expect(store.session(id)?.message == "Which icon?")
        #expect(store[TestBoard.projectID]?.state(at: .now) == .waiting)
    }

    @Test func aPermissionNeedsYou() {
        prompt("Run the tests")
        store.hook("Notification", id, ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
        #expect(store.session(id)?.state == .waiting)
        #expect(store.session(id)?.message == "Claude needs your permission to use Bash")
        // Answering it carries on the turn.
        store.hook("PostToolUse", id, ["tool_name": "Bash", "tool_input": ["command": "swift test", "description": "Run the tests"]])
        #expect(store.session(id)?.state == .working)
        #expect(store.session(id)?.message == nil)
    }

    @Test func aTurnEndingWithAQuestionIsYourCall() {
        prompt("Ship the build")
        wrapUp(ask: "Commit it and push?")
        store.hook("Stop", id)
        #expect(store.session(id)?.state == .yourCall)
        #expect(store.session(id)?.message == "Commit it and push?")
    }

    @Test func aBlockingQuestionNeedsYou() {
        prompt("Ship the build")
        wrapUp(ask: "Deploy the schema, then tell me", blocked: true)
        store.hook("Stop", id)
        #expect(store.session(id)?.state == .waiting)
    }

    @Test func aTurnEndingWithoutAQuestionIsIdle() {
        prompt("Ship the build")
        wrapUp()
        store.hook("Stop", id)
        #expect(store.session(id)?.state == .idle)
        #expect(store.session(id)?.ask == nil)
    }

    /// Claude Desktop stops an idle chat's process (SessionEnd) and starts it again when you open the
    /// chat (SessionStart, resume): the question waits for you all along.
    @Test func aQuestionOutlastsDesktopStoppingTheChat() {
        prompt("Ship the build")
        wrapUp(ask: "Commit it and push?")
        store.hook("Stop", id)
        store.hook("SessionEnd", id, ["reason": "other"])
        #expect(store.session(id)?.state == .yourCall)

        store.hook("SessionStart", id, ["source": "resume"])
        #expect(store.session(id)?.state == .yourCall)
        #expect(store.session(id)?.ask == "Commit it and push?")

        prompt("Yes, commit it")
        #expect(store.session(id)?.state == .working)
        #expect(store.session(id)?.ask == nil)
    }

    @Test func clearingTheChatEndsTheSession() {
        prompt("Ship the build")
        wrapUp(ask: "Commit it and push?")
        store.hook("Stop", id)
        store.hook("SessionEnd", id, ["reason": "clear"])
        #expect(store.session(id) == nil)
    }

    @Test func aSessionEndingWithNothingToAskGoes() {
        prompt("Ship the build")
        store.hook("Stop", id)
        store.hook("SessionEnd", id, ["reason": "other"])
        #expect(store.session(id) == nil)
    }

    @Test func resumingWithoutAQuestionIsIdle() {
        prompt("Ship the build")
        store.hook("SessionStart", id, ["source": "resume"])
        #expect(store.session(id)?.state == .idle)
    }

    @Test func aFreshStartForgetsTheQuestion() {
        prompt("Ship the build")
        wrapUp(ask: "Commit it and push?")
        store.hook("Stop", id)
        store.hook("SessionStart", id, ["source": "startup"])
        #expect(store.session(id)?.state == .idle)
        #expect(store.session(id)?.ask == nil)
    }

    @Test func compactingCarriesOn() {
        prompt("Ship the build")
        store.hook("PreCompact", id)
        #expect(store.session(id)?.mode == .compacting)
        store.hook("SessionStart", id, ["source": "compact"])
        #expect(store.session(id)?.state == .working)
        #expect(store.session(id)?.mode == nil)
    }

    @Test func anAPIErrorBlocks() {
        prompt("Ship the build")
        store.hook("StopFailure", id, ["error": "Overloaded"])
        #expect(store.session(id)?.state == .blocked)
        #expect(store.session(id)?.message != nil)
        #expect(store[TestBoard.projectID]?.state(at: .now) == .blocked)
    }

    /// Work a turn started in the background keeps the session ticking over until it reports back.
    @Test func backgroundWorkIsWaitedOn() {
        prompt("Upload build 12")
        store.hook("PostToolUse", id, ["tool_name": "Bash",
                                       "tool_input": ["command": "scripts/testflight.sh", "description": "Upload to TestFlight", "run_in_background": true],
                                       "tool_response": ["backgroundTaskId": "b7"]])
        store.hook("Stop", id)
        #expect(store.session(id)?.state == .background)
        #expect(store.session(id)?.jobsSummary(at: .now) == "Upload to TestFlight")

        // Its result wakes the session, in the app's words, not yours: the task stands.
        prompt("<task-notification><task-id>b7</task-id><status>completed</status></task-notification>")
        #expect(store.session(id)?.task == "Upload build 12")
        #expect(store.session(id)?.appTurn == true)
        #expect(store.session(id)?.background?.isEmpty == true)
        store.hook("Stop", id)
        #expect(store.session(id)?.state == .idle)
    }

    @Test func aBuildSaysItsBuilding() {
        prompt("Build it")
        store.hook("PreToolUse", id, ["tool_name": "Bash", "tool_input": ["command": "xcodebuild -scheme SoftwareFactory build", "description": "Build the Mac app"]])
        #expect(store.session(id)?.mode == .building)
        #expect(store.session(id)?.activity == "Build the Mac app")
    }

    @Test func thePlanBecomesItsSteps() {
        prompt("Build to-dos on the iPhone")
        store.hook("PostToolUse", id, ["tool_name": "mcp__ccd_turn__update_plan",
                                       "tool_input": ["items": [["content": "Read the code", "status": "in_progress"],
                                                                ["content": "Write it", "status": "pending"],
                                                                ["content": "Test it", "status": "pending"]]]])
        #expect(store.session(id)?.steps.map(\.status) == [.active, .todo, .todo])
        store.hook("PostToolUse", id, ["tool_name": "mcp__ccd_turn__update_plan", "tool_input": ["advance": true]])
        #expect(store.session(id)?.steps.map(\.status) == [.done, .active, .todo])
        store.hook("PostToolUse", id, ["tool_name": "mcp__ccd_turn__update_plan", "tool_input": ["done": [2], "start": 3]])
        #expect(store.session(id)?.steps.map(\.status) == [.done, .done, .active])
        wrapUp()
        #expect(store.session(id)?.steps.map(\.status) == [.done, .done, .done])
    }

    @Test func aWorktreeFoldsIntoItsProject() {
        store.applyClaudeHook(["hook_event_name": "UserPromptSubmit", "session_id": id, "prompt": "Try the new menu",
                               "cwd": TestBoard.projectFolder + "/.claude/worktrees/clever-elbakyan"])
        #expect(store.session(id)?.worktree == "clever-elbakyan")
        #expect(store.projects.count == 1)
    }

    @Test func temporaryFoldersAreNeverProjects() {
        #expect(store.applyClaudeHook(["hook_event_name": "UserPromptSubmit", "session_id": id, "prompt": "Hi", "cwd": "/private/tmp/scratch"]) == nil)
        #expect(store.projects.isEmpty)
    }

    /// The board takes each chat's Remote Control session from Claude Desktop's file for it, newest
    /// last, and lets it go once Remote Control is off.
    @Test func aChatsRemoteControlLinkReachesItsSession() async throws {
        let file = try TestBoard.writeChat(session: id, bridges: ["session_01Old", "session_01New"], remoteControl: true)
        defer { try? FileManager.default.removeItem(at: file) }
        prompt("Ship the build")
        wrapUp(ask: "Commit it and push?")
        store.hook("Stop", id)
        store.refreshDesktopChats()
        #expect(await eventually { store.session(id)?.remoteControl == "session_01New" })
        #expect(store.session(id)?.claudeURL?.absoluteString == "https://claude.ai/code/session_01New")

        _ = try TestBoard.writeChat(id: file.deletingPathExtension().lastPathComponent, session: id, bridges: ["session_01New"], remoteControl: false)
        store.refreshDesktopChats()
        #expect(await eventually { store.session(id)?.remoteControl == nil })
    }
}
