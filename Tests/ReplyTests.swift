import Foundation
import Testing

/// Replying to a turn that ended, from the board or the iPhone: Claude Desktop's next-step buttons,
/// or your own words, which the reply hook hands Claude Code to wake the session with.
@MainActor
@Suite("Replies")
struct ReplyTests {
    let store = TestBoard.make()
    let desk = PermissionDesk.shared
    let id = UUID().uuidString
    let ask = "Fix the raised thumb next, or regenerate the glove in Meshy with clean fingers?"

    /// A turn that ends with Claude Desktop's next-step box: a question, two replies and an app action.
    private func endTurn() {
        store.hook("UserPromptSubmit", id, ["prompt": "Rig the glove for the fighter"])
        store.hook("PostToolUse", id, ["tool_name": "mcp__ccd_turn__wrap_up", "tool_input": [
            "recap": "The glove is rigged.", "ask": ask,
            "actions": [["label": "Fix the thumb"], ["label": "Regenerate the glove"], ["label": "Commit", "action": "commit"]],
        ] as [String: Any]])
        store.hook("Stop", id)
    }

    /// The reply hook's request, as Claude Code's Stop hook sends it.
    private func replyHook() throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": id, "cwd": TestBoard.projectFolder])
        return API.handle(HTTPRequest(method: "POST", path: "api/hooks/claude/reply", query: [:], headers: ["host": "127.0.0.1:7720"], body: body),
                          store: store)
    }

    @Test func theNextStepBoxsRepliesAreKept() {
        endTurn()
        #expect(store.session(id)?.state == .yourCall)
        // A button for one of the app's own actions isn't a reply.
        #expect(store.session(id)?.askOptions == ["Fix the thumb", "Regenerate the glove"])
        #expect(store.session(id)?.askWithOptions == ask + "\nFix the thumb · Regenerate the glove")
        store.hook("UserPromptSubmit", id, ["prompt": "Fix the thumb"])
        #expect(store.session(id)?.askOptions == nil)
    }

    /// The hook's request waits; a reply on the board is what it hands back, and the session works again.
    @Test func theAPIHoldsTheReplyHookUntilYouReply() async throws {
        endTurn()
        let later = try #require(try replyHook().later)
        let hook = Task { await later() }
        #expect(await eventually { desk.canReply(to: id) })
        #expect(store.session(id)?.canReply(at: .now) == true)
        #expect(store[TestBoard.projectID]?.openReply(at: .now)?.id == id)

        #expect(store.reply(to: id, text: "Fix the thumb", from: "the iPhone"))
        let woken = String(decoding: await hook.value.body, as: UTF8.self)
        #expect(woken == "The user replied from Software Factory, on the iPhone: Fix the thumb")
        #expect(store.session(id)?.state == .working)
        #expect(store.session(id)?.ask == nil)
        #expect(store.session(id)?.replyUntil == nil)
        #expect(store[TestBoard.projectID]?.events.first?.title == "Replied on the iPhone")
        #expect(store[TestBoard.projectID]?.events.first?.detail == "Fix the thumb")

        // The turn the reply starts is yours, and keeps the task.
        store.hook("UserPromptSubmit", id, ["prompt": "<system-reminder>\(woken)</system-reminder>"])
        #expect(store.session(id)?.appTurn == false)
        #expect(store.session(id)?.task == "Rig the glove for the fighter")
    }

    /// Writing in Claude instead lets the hook go, with nothing to wake the session with.
    @Test func aPromptInClaudeLetsTheHookGo() async throws {
        endTurn()
        let later = try #require(try replyHook().later)
        let hook = Task { await later() }
        #expect(await eventually { desk.canReply(to: id) })
        store.hook("UserPromptSubmit", id, ["prompt": "Regenerate the glove"])
        #expect(await hook.value.body.isEmpty)
        #expect(!desk.canReply(to: id))
        #expect(store.session(id)?.replyUntil == nil)
        // Too late now: the reply isn't sent, and the timeline says so.
        #expect(!store.reply(to: id, text: "Fix the thumb", from: "the iPhone"))
        #expect(store[TestBoard.projectID]?.events.first?.title == "Couldn't pass on your reply from the iPhone")
    }

    /// Claude Desktop stops a chat's process half an hour after its turn ends, and the hook with it.
    @Test func theChatStoppingLetsTheHookGo() async throws {
        endTurn()
        let later = try #require(try replyHook().later)
        let hook = Task { await later() }
        #expect(await eventually { desk.canReply(to: id) })
        store.hook("SessionEnd", id, ["reason": "other"])
        #expect(await hook.value.body.isEmpty)
        // The question still waits for you, in Claude.
        #expect(store.session(id)?.state == .yourCall)
        #expect(store.session(id)?.canReply(at: .now) == false)
    }

    /// A session's next turn can end before the hook for the one before has let go: the newer one
    /// takes the reply, and the older's time running out doesn't take it from the newer.
    @Test func theNewestHookTakesTheReply() async {
        let first = Task { await desk.reply(for: id, until: .now.addingTimeInterval(0.3)) }
        #expect(await eventually { desk.canReply(to: id) })
        let second = Task { await desk.reply(for: id, until: .now.addingTimeInterval(60)) }
        #expect(await first.value == nil)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(desk.canReply(to: id))
        #expect(desk.settleReply(id, with: "Go on"))
        #expect(await second.value == "Go on")
    }

    @Test func theAPITakesAReplyBySession() async throws {
        let wait = Task { await desk.reply(for: id, until: .now.addingTimeInterval(60)) }
        #expect(await eventually { desk.canReply(to: id) })
        let request = HTTPRequest(method: "POST", path: "api/sessions/\(id)/reply", query: [:], headers: ["host": "127.0.0.1:7720"],
                                  body: Data(#"{"text": "Ship it"}"#.utf8))
        #expect(String(decoding: API.handle(request, store: store).body, as: UTF8.self).contains(#"{"sent":true}"#))
        #expect(await wait.value == "The user replied from Software Factory, on this Mac: Ship it")
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
            p.sessions[index].replyUntil = start.addingTimeInterval(600)
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

    @Test func theIPhonesReplyReachesTheHook() async {
        endTurn()
        let wait = Task { await desk.reply(for: id, until: .now.addingTimeInterval(60)) }
        #expect(await eventually { desk.canReply(to: id) })
        let change = CloudBoard.Change(kind: .reply, project: TestBoard.projectID, answered: .now, session: id, text: "Fix the thumb")
        #expect(PhoneShare.fold(change, into: store, digests: DigestStore.shared))
        #expect(await wait.value == "The user replied from Software Factory, on the iPhone: Fix the thumb")
        // One for a session this Mac never had waits for the Mac that has it.
        let elsewhere = CloudBoard.Change(kind: .reply, answered: .now, session: UUID().uuidString, text: "Yes")
        #expect(!PhoneShare.fold(elsewhere, into: store, digests: DigestStore.shared))
    }

    // MARK: - Installing the hook

    @Test func theReplyHookRunsInTheBackground() throws {
        let hooks = ClaudeSetup.hooks([:], adding: ClaudeSetup.command(port: 7720))
        let stops = try #require(hooks["Stop"] as? [[String: Any]]).compactMap { ($0["hooks"] as? [[String: Any]])?.first }
        #expect(stops.count == 2)
        let reply = try #require(stops.first { $0["asyncRewake"] as? Bool == true })
        #expect(reply["command"] as? String == ClaudeSetup.replyCommand(port: 7720))
        #expect(reply["timeout"] as? Int == Int(ClaudeSetup.replyWait) + 60)
        #expect(ClaudeSetup.upgrade(for: hooks) == nil)

        // Hooks from before it had one get it, with the same command.
        var older = hooks
        older["Stop"] = [["hooks": [stops.first { $0["asyncRewake"] == nil }!]]]
        #expect(ClaudeSetup.upgrade(for: older) == ClaudeSetup.command(port: 7720))
    }

    /// The reply goes to Claude Code on stderr, and exit 2 wakes the session with it.
    @Test func theReplyHookWakesClaudeWithTheReply() throws {
        let command = ClaudeSetup.replyCommand(port: 7720)
        #expect(command.contains("/api/hooks/claude/reply"))
        #expect(command.contains(#">&2; exit 2;"#))
        #expect(command.hasSuffix("exit 0 " + ClaudeSetup.marker))

        let path = "/Users/someone/Tools's/factory"
        #expect(ClaudeSetup.replyCommand(like: ClaudeSetup.command(factory: path)) == ClaudeSetup.replyCommand(factory: path))
        #expect(ClaudeSetup.replyCommand(factory: path).hasPrefix(#"'/Users/someone/Tools'\''s/factory' hook --reply;"#))
    }

    /// The shell the hook runs in hands on what the board says, and stays quiet when it says nothing.
    @Test func theReplyHooksShellDoesWhatItSays() throws {
        let board = try #require(ClaudeSetup.replyCommand(port: 7720).firstMatch(of: #/^reply=\$\((.*?)\) && /#)?.1)
        func run(_ answer: String) throws -> (status: Int32, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let script = ClaudeSetup.replyCommand(port: 7720).replacingOccurrences(of: String(board), with: "printf '%s' '\(answer)'")
            process.arguments = ["-c", script]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        #expect(try run("The user replied: Go") == (2, "The user replied: Go\n"))
        #expect(try run("") == (0, ""))
    }
}
