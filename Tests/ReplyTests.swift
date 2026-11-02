import Foundation
import Testing

/// Answering a turn that ended asking you something (Claude Desktop's next-step box), from the board
/// or the iPhone: the session carries on in a chat the board runs, starting with your answer. The
/// chat itself is in `ChatTests`; this is the asking, and how the answer finds its way.
@MainActor
@Suite("Replies")
struct ReplyTests {
    let store = TestBoard.make()
    let id = UUID().uuidString
    let ask = "Fix the raised thumb next, or regenerate the glove in Meshy with clean fingers?"

    /// A turn that ends with Claude Desktop's next-step box: a question, two replies and an app action.
    private func endTurn(transcript: String? = "/Users/someone/.claude/projects/moth/\(UUID().uuidString).jsonl") {
        var prompt: [String: Any] = ["prompt": "Rig the glove for the fighter"]
        if let transcript { prompt["transcript_path"] = transcript }
        store.hook("UserPromptSubmit", id, prompt)
        store.hook("PostToolUse", id, ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": [
            "recap": "The glove is rigged.", "ask": ask,
            "actions": [["label": "Fix the thumb"], ["label": "Regenerate the glove"], ["label": "Commit", "action": "commit"]],
        ] as [String: Any]])
        store.hook("Stop", id)
    }

    @Test func theNextStepBoxsRepliesAreKept() {
        endTurn()
        #expect(store.session(id)?.state == .yourCall)
        // A button for one of the app's own actions isn't a reply.
        #expect(store.session(id)?.askOptions == ["Fix the thumb", "Regenerate the glove"])
        #expect(store.session(id)?.askWithOptions == ask + "\nFix the thumb · Regenerate the glove")
        #expect(store[TestBoard.projectID]?.openReply(at: .now)?.id == id)
        store.hook("UserPromptSubmit", id, ["prompt": "Fix the thumb"])
        #expect(store.session(id)?.askOptions == nil)
    }

    /// Only a session whose transcript is on this Mac can be carried on here, and not one the board runs.
    @Test func onlyThisMacsSessionsCarryOn() throws {
        endTurn()
        #expect(store.canContinue(try #require(store.session(id))))
        var elsewhere = try #require(store.session(id))
        elsewhere.machine = "Ratatoskr"
        #expect(!store.canContinue(elsewhere))
        elsewhere.machine = nil
        elsewhere.transcript = nil
        #expect(!store.canContinue(elsewhere))
    }

    /// Its folder isn't on this Mac (the test project's never is): nothing starts, and nothing changes.
    @Test func aSessionThatCantCarryOnStaysAsItWas() {
        endTurn()
        #expect(store.continueInChat(id, saying: "Fix the thumb", from: "this Mac") == nil)
        #expect(store.session(id)?.state == .yourCall)
        #expect(store.session(id)?.ask == ask)
        let request = HTTPRequest(method: "POST", path: "api/sessions/\(id)/reply", query: [:], headers: ["host": "127.0.0.1:7720"],
                                  body: Data(#"{"text": "Fix the thumb"}"#.utf8))
        #expect(API.handle(request, store: store).status == 409)
    }

    /// Two sessions asking at once, as Volt Crystal's did: each question says which session it's from,
    /// and one you won't answer can be dismissed, here or from the iPhone.
    @Test func aQuestionSaysWhichSessionAndCanBeDismissed() throws {
        endTurn()
        let other = UUID().uuidString
        store.hook("UserPromptSubmit", other, ["prompt": "Rig the fighter's guard pose"])
        store.hook("PostToolUse", other, ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": ["ask": "Fix his guard pose next?"] as [String: Any]])
        store.hook("Stop", other)
        // It runs in a worktree, as its hooks' folder would say.
        store.update(TestBoard.projectID) { p in
            guard let index = p.sessions.firstIndex(where: { $0.id == other }) else { return }
            p.sessions[index].worktree = "awesome-lumiere-fa9e40"
        }
        let project = try #require(store[TestBoard.projectID])
        let guardPose = try #require(project.sessions.first { $0.id == other })
        #expect(project.askLabel(for: guardPose, at: .now) == "awesome-lumiere-fa9e40 · Rig the fighter's guard pose")
        #expect(project.askLabel(for: try #require(store.session(id)), at: .now) == "Main folder · Rig the glove for the fighter")

        store.dismissAsk(other, from: "this Mac")
        #expect(store.session(other)?.ask == nil)
        #expect(store.session(other)?.state == .idle)
        #expect(store[TestBoard.projectID]?.events.first?.title == "Dismissed on this Mac")
        #expect(store[TestBoard.projectID]?.events.first?.detail == "Fix his guard pose next?")
        // With one session asking, no label.
        #expect(store[TestBoard.projectID]?.openReply(at: .now)?.id == id)

        // From the iPhone.
        let change = CloudBoard.Change(kind: .dismiss, project: TestBoard.projectID, answered: .now, session: id)
        #expect(PhoneShare.fold(change, into: store, digests: DigestStore.shared))
        #expect(store.session(id)?.ask == nil)
        #expect(store[TestBoard.projectID]?.openReply(at: .now) == nil)
    }

    // MARK: - Notifications

    @Test func aNotificationsButtonsSayTheReplies() {
        endTurn()
        #expect(Notifier.reply(action: "option.1", text: nil, to: id, in: store) == "Regenerate the glove")
        #expect(Notifier.reply(action: "reply", text: " Both, thumb first \n", to: id, in: store) == "Both, thumb first")
        #expect(Notifier.reply(action: "option.5", text: nil, to: id, in: store) == nil)
        #expect(Notifier.reply(action: "open-chat", text: nil, to: id, in: store) == nil)
    }

    // MARK: - The iPhone

    /// The alert is named for the reply, with the options on the body's last line for the extension.
    @Test func theIPhonesAlertCarriesTheOptions() throws {
        endTurn()
        let start = Date.now
        store.update(TestBoard.projectID) { p in
            guard let index = p.sessions.firstIndex(where: { $0.id == id }) else { return }
            p.sessions[index].since = start.addingTimeInterval(-PhoneShare.alertDelay)
        }
        let project = try #require(store[TestBoard.projectID])
        let alert = try #require(PhoneShare.alertsDue(in: [project], now: start, sent: []).first)
        let reply = try #require(PermissionAlert.reply(fromRecordName: alert.id))
        #expect(reply.session == id)
        #expect(reply.options == 2)
        #expect(PermissionAlert.options(inBody: alert.body, count: reply.options) == ["Fix the thumb", "Regenerate the glove"])
        // A body whose last line isn't the options it should list gets none.
        #expect(PermissionAlert.options(inBody: ask, count: 2).isEmpty)
        #expect(PermissionAlert.options(inBody: "Which?\nA · B · C", count: 2).isEmpty)
    }

    /// One this Mac doesn't have waits, a day at most, for the Mac that has it.
    @Test func theIPhonesReplyWaitsForItsMac() {
        let change = CloudBoard.Change(kind: .reply, answered: .now, session: UUID().uuidString, text: "Yes", chat: UUID().uuidString)
        #expect(!PhoneShare.fold(change, into: store, digests: DigestStore.shared))
        #expect(PhoneShare.fold(change, into: store, digests: DigestStore.shared, now: .now.addingTimeInterval(2 * 86_400)))
    }

    // MARK: - Installing the hooks

    /// An earlier version's reply hook (Stop, in the background, waking the session) comes out when
    /// the hooks are installed again: Claude Desktop doesn't take what it wakes a session with as yours.
    @Test func theOldReplyHookComesOut() throws {
        let command = ClaudeSetup.command(port: 7720)
        let hooks = ClaudeSetup.hooks([:], adding: command)
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 1)
        #expect(ClaudeSetup.upgrade(for: hooks) == nil)

        var older = hooks
        older["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [["hooks": [[
            "type": "command", "asyncRewake": true, "timeout": 7260,
            "command": "reply=$(curl -sf --connect-timeout 1 -m 7230 --data-binary @- http://127.0.0.1:7720/api/hooks/claude/reply) && exit 2; exit 0 # software-factory",
        ]]]]
        #expect(ClaudeSetup.upgrade(for: older) == command)
        let again = ClaudeSetup.hooks(older.filter { $0.key != "Stop" }, adding: command)
        #expect((again["Stop"] as? [[String: Any]])?.count == 1)
        // Until then it gets nothing to wait for.
        let request = HTTPRequest(method: "POST", path: "api/hooks/claude/reply", query: [:], headers: ["host": "127.0.0.1:7720"], body: Data("{}".utf8))
        #expect(API.handle(request, store: store).body.isEmpty)
    }
}
