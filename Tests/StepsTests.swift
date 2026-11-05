import Foundation
import Testing

/// A turn's steps, ticked off as it finishes: Claude often leaves the last one it was on unticked,
/// in its own to-do list or in the checklist it reported (`factory steps`, `factory advance`).
@MainActor
@Suite("Steps at a turn's end")
struct StepsTests {
    let store = TestBoard.make()
    let id = UUID().uuidString

    private func report(_ json: String) throws {
        try store.apply(JSONDecoder().decode(Report.self, from: Data(json.utf8)), to: TestBoard.projectID)
    }

    private var checklist: [Step.Status] { store[TestBoard.projectID]?.steps.map(\.status) ?? [] }

    @Test func aFinishedTurnTicksOffItsLastStep() throws {
        store.hook("UserPromptSubmit", id, ["prompt": "Compare the Android UI with the Mac"])
        try report(#"{"steps": [{"title": "Build for Android", "status": "done"}, {"title": "Compare UI with the Mac", "status": "active"}]}"#)
        store.hook("PostToolUse", id, ["tool_name": "TodoWrite", "tool_input": ["todos": [
            ["content": "Shoot the screens", "status": "completed"], ["content": "Fix the layout", "status": "in_progress"],
        ]]])
        store.hook("Stop", id)
        #expect(checklist == [.done, .done])
        #expect(store.session(id)?.steps.map(\.status) == [.done, .done])
        #expect(store[TestBoard.projectID]?.events.contains { $0.title == "Compare UI with the Mac" && $0.detail == "Step done" } == true)
    }

    /// A turn that ends asking you something may be part way through: its steps stay as they are.
    @Test func aQuestionLeavesTheStepsBe() throws {
        store.hook("UserPromptSubmit", id, ["prompt": "Compare the Android UI with the Mac"])
        try report(#"{"steps": [{"title": "Build for Android", "status": "done"}, {"title": "Compare UI with the Mac", "status": "active"}]}"#)
        store.hook("PostToolUse", id, ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": ["ask": "Fix the panels next?"] as [String: Any]])
        store.hook("Stop", id)
        #expect(checklist == [.done, .active])
    }

    /// Only the checklist this turn reported is its to finish; steps not yet started stay unticked.
    @Test func anEarlierChecklistAndLaterStepsStayAsTheyAre() throws {
        store.hook("SessionStart", id)
        try report(#"{"steps": [{"title": "Survey", "status": "done"}, {"title": "Compile", "status": "active"}]}"#)
        store.hook("UserPromptSubmit", id, ["prompt": "Something else"])
        store.hook("Stop", id)
        #expect(checklist == [.done, .active])

        store.hook("UserPromptSubmit", id, ["prompt": "Carry on"])
        try report(#"{"steps": [{"title": "Compile", "status": "done"}, {"title": "Run", "status": "active"}, {"title": "Ship", "status": "todo"}]}"#)
        store.hook("Stop", id)
        #expect(checklist == [.done, .done, .todo])
    }

    /// Another session still at work in the project may be the one on it.
    @Test func anotherSessionAtWorkKeepsItsChecklist() throws {
        let other = UUID().uuidString
        store.hook("UserPromptSubmit", other, ["prompt": "Balance the runs"])
        store.hook("UserPromptSubmit", id, ["prompt": "Fix a typo"])
        try report(#"{"steps": [{"title": "Balance runs", "status": "active"}]}"#)
        store.hook("Stop", id)
        #expect(checklist == [.active])
    }

    // MARK: - Auto mode's blocks

    @Test func autoModesBlocksAreInTheTimeline() throws {
        store.hook("UserPromptSubmit", id, ["prompt": "Merge and push and clean up"])
        store.hook("PermissionDenied", id, ["tool_name": "Bash", "tool_input": ["command": "git push origin --delete worktree-fighter-four"],
                                            "reason": "[Git Destructive]"])
        let event = try #require(store[TestBoard.projectID]?.events.first)
        #expect(event.title == "Auto mode wouldn't let it run git push origin --delete worktree-fighter-four")
        #expect(event.detail == "Git Destructive")
        #expect(event.state == .blocked)
        // The turn goes on.
        #expect(store.session(id)?.state == .working)
        #expect(HookText.denialReason("Auto mode could not evaluate this action and is blocking it for safety") == "Auto mode couldn't judge it, so it stopped it")

        let hooks = ClaudeSetup.hooks([:], adding: ClaudeSetup.command(port: 7720))
        #expect((hooks["PermissionDenied"] as? [[String: Any]])?.first?["matcher"] as? String == "*")
    }
}
