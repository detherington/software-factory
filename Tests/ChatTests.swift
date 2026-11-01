import Foundation
import Testing

/// Sessions the board runs itself: Claude Code's stream-json, read and written, and a whole turn
/// against a stand-in for `claude` that speaks it.
@MainActor
@Suite("Hosted chats", .serialized)
struct ChatTests {
    let host = SessionHost.shared
    let desk = PermissionDesk.shared

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Reading what Claude Code says

    @Test func readsAReplyBlockByBlock() throws {
        guard case .started(let session, let model) = StreamJSON.parse(line(["type": "system", "subtype": "init", "session_id": "s1", "model": "claude-opus-5-5"])) else {
            Issue.record("No start"); return
        }
        #expect(session == "s1")
        #expect(model == "claude-opus-5-5")
        // A hook's note isn't the start.
        guard case .other = StreamJSON.parse(line(["type": "system", "subtype": "hook_started", "session_id": "s1"])) else { Issue.record("A hook note"); return }

        // Claude Code sends a reply's blocks as messages of their own, sharing the API message's id.
        let words = StreamJSON.parse(line(["type": "assistant", "uuid": "u1", "message": ["id": "m1", "content": [["type": "text", "text": "Running the tests.\n"]]]]))
        let tool = StreamJSON.parse(line(["type": "assistant", "uuid": "u2", "message": ["id": "m1", "content": [
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "make test", "description": "Run the tests"]],
        ]]]))
        guard case .items(let said) = words, case .items(let used) = tool else { Issue.record("No items"); return }
        #expect(said.map(\.text) == ["Running the tests."])
        #expect(said.first?.kind == .assistant)
        #expect(used.first?.id == "t1")
        #expect(used.first?.kind == .tool)
        #expect(used.first?.detail == "make test")
        #expect(said.first?.id != used.first?.id)
    }

    @Test func readsToolResultsAndWhatYouWrote() {
        let result = StreamJSON.parse(line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "1 test failed"],
            ["type": "tool_result", "tool_use_id": "t2", "content": [["type": "text", "text": "ok"]]],
        ]]]))
        guard case .toolResults(let results) = result else { Issue.record("No results"); return }
        #expect(results.map(\.id) == ["t1", "t2"])
        #expect(results.map(\.failed) == [true, false])
        #expect(results.first?.output == "1 test failed")

        guard case .items(let wrote) = StreamJSON.parse(line(["type": "user", "uuid": "w1", "message": ["role": "user", "content": "Fix the thumb"]])) else {
            Issue.record("Not replayed"); return
        }
        #expect(wrote.first?.kind == .user)
        #expect(wrote.first?.text == "Fix the thumb")
        // What the app adds isn't you.
        guard case .other = StreamJSON.parse(line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "Caveat: the messages below"]])),
              case .other = StreamJSON.parse(line(["type": "user", "message": ["role": "user", "content": "<system-reminder>Notes</system-reminder>"]])) else {
            Issue.record("Taken as yours"); return
        }
    }

    @Test func readsATurnsEndAndPrompts() {
        guard case .finished(let duration, nil) = StreamJSON.parse(line(["type": "result", "subtype": "success", "is_error": false, "duration_ms": 1500])) else {
            Issue.record("No end"); return
        }
        #expect(duration == 1.5)
        guard case .finished(_, let error) = StreamJSON.parse(line(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login"])) else {
            Issue.record("No failed end"); return
        }
        #expect(error == "Not logged in · Please run /login")
        #expect(SessionHost.needsSignIn(error ?? ""))

        guard case .permission(let request, let tool, let input) = StreamJSON.parse(line(["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "git push"], "tool_use_id": "t3",
        ]])) else { Issue.record("No prompt"); return }
        #expect(request == "r1")
        #expect(tool == "Bash")
        #expect(input["command"] as? String == "git push")
        guard case .cancelled("r1") = StreamJSON.parse(line(["type": "control_cancel_request", "request_id": "r1"])) else { Issue.record("No cancel"); return }
    }

    // MARK: - Writing to it

    @Test func writesAsYouAndAnswersPrompts() throws {
        let message = try #require(JSONSerialization.jsonObject(with: StreamJSON.userMessage("Ship it")) as? [String: Any])
        #expect(message["type"] as? String == "user")
        #expect((message["message"] as? [String: Any])?["content"] as? String == "Ship it")
        #expect(StreamJSON.userMessage("x").last == 0x0A)

        let allow = try #require(JSONSerialization.jsonObject(with: StreamJSON.answer("r1", allow: true, input: ["questions": []], answers: ["Which?": "Grid"], from: "the iPhone")) as? [String: Any])
        let response = try #require(allow["response"] as? [String: Any])
        #expect(allow["type"] as? String == "control_response")
        #expect(response["request_id"] as? String == "r1")
        let decision = try #require(response["response"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect((decision["updatedInput"] as? [String: Any])?["answers"] as? [String: String] == ["Which?": "Grid"])

        let deny = try #require(JSONSerialization.jsonObject(with: StreamJSON.answer("r2", allow: false, input: [:], from: "this Mac")) as? [String: Any])
        #expect(((deny["response"] as? [String: Any])?["response"] as? [String: Any])?["message"] as? String == "The user denied this in Software Factory, on this Mac.")

        let interrupt = try #require(JSONSerialization.jsonObject(with: StreamJSON.interrupt("i1")) as? [String: Any])
        #expect((interrupt["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
    }

    /// A new chat picks its session's id; a chat that ran before resumes it; carrying on another
    /// session forks it, so that one stays as it was.
    @Test func startsNewResumesOrForks() {
        var chat = HostedChat(id: "c1", project: "p", items: [], status: .ended, updated: .now)
        #expect(SessionHost.arguments(for: chat).suffix(2) == ["--session-id", "c1"])
        #expect(SessionHost.arguments(for: chat).contains("--permission-prompt-tool"))
        chat.continues = "desktop-1"
        #expect(SessionHost.arguments(for: chat).suffix(5) == ["--resume", "desktop-1", "--fork-session", "--session-id", "c1"])
        chat.began = .now
        #expect(SessionHost.arguments(for: chat).suffix(2) == ["--resume", "c1"])
    }

    @Test func readsTheConversationSoFarFromATranscript() throws {
        let transcript = TestBoard.folder.appending(path: "\(UUID().uuidString).jsonl")
        let lines: [[String: Any]] = [
            ["type": "user", "uuid": "1", "cwd": "/Users/someone/Moth Radio", "timestamp": "2026-10-30T12:00:00.000Z",
             "message": ["role": "user", "content": "Add a sleep timer"]],
            ["type": "assistant", "uuid": "2", "timestamp": "2026-10-30T12:00:05.000Z",
             "message": ["id": "m", "content": [["type": "text", "text": "On it."], ["type": "tool_use", "id": "t", "name": "Edit", "input": ["file_path": "/x/Timer.swift"]]]]],
            ["type": "user", "uuid": "3", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "is_error": true, "content": "No such file"]]]],
            ["type": "user", "uuid": "4", "isMeta": true, "message": ["role": "user", "content": "Caveat"]],
        ]
        try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let history = SessionHost.history(of: transcript)
        #expect(history.folder == "/Users/someone/Moth Radio")
        #expect(history.items.map(\.kind) == [.user, .assistant, .tool])
        #expect(history.items.last?.failed == true)
        #expect(history.items.first?.date == (try Date("2026-10-30T12:00:00Z", strategy: .iso8601)))
    }

    // MARK: - A whole turn

    /// A stand-in for `claude`: it answers, asks to run a command, and once allowed, runs it and ends the turn.
    private func stub() throws -> URL {
        let script = TestBoard.folder.appending(path: "claude-stub-\(UUID().uuidString)")
        try #"""
        #!/usr/bin/python3
        import sys, json
        args = sys.argv[1:]
        session = args[args.index("--session-id") + 1] if "--session-id" in args else args[args.index("--resume") + 1]
        def out(o):
            sys.stdout.write(json.dumps(o) + "\n")
            sys.stdout.flush()
        started = False
        for line in sys.stdin:
            m = json.loads(line)
            if m.get("type") == "user":
                text = m["message"]["content"]
                if not started:
                    out({"type": "system", "subtype": "init", "session_id": session, "model": "claude-test-1"})
                    started = True
                out({"type": "user", "uuid": "you-" + text, "message": {"role": "user", "content": text}})
                out({"type": "assistant", "uuid": "a1", "message": {"id": "m1", "content": [{"type": "text", "text": "Running the tests."}]}})
                out({"type": "control_request", "request_id": "perm-1", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "make test"}, "tool_use_id": "t1"}})
            elif m.get("type") == "control_response":
                decision = m["response"]["response"]
                if decision["behavior"] == "allow":
                    out({"type": "assistant", "uuid": "a2", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": decision["updatedInput"]}]}})
                    out({"type": "user", "uuid": "r1", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "is_error": True, "content": "1 test failed"}]}})
                out({"type": "assistant", "uuid": "a3", "message": {"id": "m2", "content": [{"type": "text", "text": "One test failed."}]}})
                out({"type": "result", "subtype": "success", "is_error": False, "duration_ms": 1500})
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test func aWholeTurnWithAPermissionPrompt() async throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["FactoryClaudePath"] = try stub().path
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            arguments["FactoryClaudePath"] = nil
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let folder = TestBoard.folder.appending(path: "Moth Radio \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(id: "moth-radio", name: "Moth Radio", path: folder.path)
        let id = try #require(host.newChat(in: project))
        #expect(host.chats[id]?.status == .ended)
        // Opened and not yet written in: not listed, kept or sent.
        #expect(!host.chats(for: project.id).contains { $0.id == id })

        #expect(host.send("Run the tests", to: id))
        #expect(host.isHosting(id))
        #expect(await eventually { host.chats[id]?.ask != nil })
        let chat = try #require(host.chats[id])
        #expect(host.chats(for: project.id).contains { $0.id == id })
        #expect(chat.title == "Run the tests")
        #expect(chat.model == "claude-test-1")
        #expect(chat.began != nil)
        #expect(chat.status == .waiting)
        #expect(chat.items.map(\.kind) == [.user, .assistant])
        let ask = try #require(chat.ask)
        #expect(ask.summary == "make test")
        #expect(desk.isWaiting(for: ask.id))

        // Allowed on the board, as its button does.
        #expect(desk.settle(ask.id, with: PermissionDesk.Answer(allow: true, from: "this Mac")))
        #expect(await eventually { host.chats[id]?.status == .idle })
        let done = try #require(host.chats[id])
        #expect(done.ask == nil)
        #expect(done.items.map(\.kind) == [.user, .assistant, .tool, .assistant, .result])
        #expect(done.items[2].failed == true)
        #expect(done.items[2].detail == "1 test failed")
        #expect(done.items.last?.text == "Done in 1 s")

        // Letting it go ends the process; writing again would resume the session.
        host.stop(id)
        #expect(await eventually { host.chats[id]?.status == .ended })
        #expect(!host.isHosting(id))
        #expect(SessionHost.arguments(for: try #require(host.chats[id])).suffix(2) == ["--resume", id])
    }

    // MARK: - The iPhone

    /// A chat travels as a Project record named for it, as the Passport does: the board tells it apart,
    /// and an iPhone build from before passes over it rather than show a project.
    @Test func aChatTravelsToTheIPhoneAsARecordOfItsOwn() throws {
        let long = String(repeating: "word ", count: 2000)
        let chat = HostedChat(id: "c1", project: "moth-radio", title: "Run the tests",
                              items: (0..<80).map { ChatItem(id: "\($0)", kind: .assistant, text: $0 == 79 ? long : "line \($0)", date: .now) },
                              status: .idle, updated: .now, folder: "/Users/someone/Moth Radio", machine: "Loki")
        let copy = chat.phoneCopy()
        #expect(copy.items.count == 60)
        #expect(copy.items.first?.id == "20")
        #expect(copy.items.last?.text.count == 4001)
        #expect(copy.folder == nil)

        let project = Project(id: "moth-radio", name: "Moth Radio", path: nil)
        let record = CloudBoard.chatRecord(try CloudBoard.encode(copy), for: chat.id)
        #expect(record.recordType == CloudBoard.projectType)
        #expect(record.recordID.recordName == "chat.c1")
        let board = CloudBoard.board(from: [CloudBoard.record(try CloudBoard.encode(project), for: project, machine: "Loki"), record])
        #expect(board.projects.map(\.id) == ["moth-radio"])
        #expect(board.chats.map(\.id) == ["c1"])
        #expect(CloudBoard.decode(Project.self, from: try #require(record[CloudBoard.Field.data] as? Data)) == nil)
    }

    /// What you write in a chat on the iPhone goes to the Mac that runs it; one this Mac doesn't run,
    /// or a new one for a project whose folder isn't here, waits for another Mac.
    @Test func theIPhonesChatChangesFindTheirMac() async throws {
        let store = TestBoard.make()
        let now = Date.now
        let elsewhere = CloudBoard.Change(kind: .message, project: "moth-radio", answered: now, session: UUID().uuidString, text: "Go on")
        #expect(!PhoneShare.fold(elsewhere, into: store, digests: DigestStore.shared, host: host, now: now))
        #expect(PhoneShare.fold(elsewhere, into: store, digests: DigestStore.shared, host: host, now: now.addingTimeInterval(2 * 86_400)))

        _ = store.hook("UserPromptSubmit", UUID().uuidString, ["prompt": "Ship it"])
        let start = CloudBoard.Change(kind: .start, project: TestBoard.projectID, projectName: "Moth Radio", answered: now,
                                      session: UUID().uuidString, text: "Add a sleep timer")
        #expect(!PhoneShare.fold(start, into: store, digests: DigestStore.shared, host: host, now: now))
        #expect(host.chats[start.session ?? ""] == nil)
    }

    // MARK: - From a to-do

    /// A chat started from a to-do begins with it, says how to tick it off, and the to-do remembers it,
    /// including as the iPhone's copy comes back.
    @Test func aToDoStartsAChatThatCanTickItOff() throws {
        let store = TestBoard.make()
        _ = store.hook("UserPromptSubmit", UUID().uuidString, ["prompt": "Ship it"])
        let todo = try #require(store.addTodo("Add a sleep timer", to: TestBoard.projectID))
        #expect(todo.chatPrompt.hasPrefix("Add a sleep timer\n\n"))
        #expect(todo.chatPrompt.contains("`factory todo done \(todo.id.uuidString)`"))
        #expect(HookText.task(from: todo.chatPrompt) == "Add a sleep timer")

        store.linkTodo(todo.id, in: TestBoard.projectID, chat: "c1")
        let linked = try #require(store[TestBoard.projectID]?.todos?.first { $0.id == todo.id })
        #expect(linked.chat == "c1")
        #expect(linked.updated >= todo.updated)

        // The iPhone ticks it off, with the link it had.
        var ticked = linked
        ticked.done = true
        ticked.updated = linked.updated.addingTimeInterval(1)
        #expect(store.mergeTodo(ticked, into: TestBoard.projectID))
        #expect(store[TestBoard.projectID]?.todos?.first { $0.id == todo.id }?.chat == "c1")

        // Ticked off by its id, as the chat is told to.
        let other = try #require(store.addTodo("Fix the thumb", to: TestBoard.projectID))
        let request = HTTPRequest(method: "PATCH", path: "api/projects/\(TestBoard.projectID)/todos/\(other.id.uuidString)", query: [:],
                                  headers: ["host": "127.0.0.1:7720"], body: Data(#"{"done": true}"#.utf8))
        _ = API.handle(request, store: store)
        #expect(store[TestBoard.projectID]?.todos?.first { $0.id == other.id }?.done == true)
    }

    // MARK: - Answering another session

    /// A Claude Desktop session's turn ended asking something: your answer carries it on in a chat here,
    /// a fork with the conversation so far, whose first message is your answer, as you.
    @Test func anAnswerCarriesASessionOnInAChat() async throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["FactoryClaudePath"] = try stub().path
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            arguments["FactoryClaudePath"] = nil
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let store = TestBoard.make()
        let folder = TestBoard.folder.appending(path: "Moth Radio \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appending(path: "session.jsonl")
        try String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": "user", "uuid": "1", "cwd": folder.path, "message": ["role": "user", "content": "Rig the glove for the fighter"],
        ]), as: UTF8.self).write(to: transcript, atomically: true, encoding: .utf8)
        let session = UUID().uuidString
        store.hook("UserPromptSubmit", session, ["prompt": "Rig the glove for the fighter", "transcript_path": transcript.path])
        store.hook("PostToolUse", session, ["tool_name": "mcp__ccd_turn__wrap_up",
                                            "tool_input": ["ask": "Fix the thumb next?", "actions": [["label": "Fix the thumb"], ["label": "Leave it"]]] as [String: Any]])
        store.hook("Stop", session)

        let chat = try #require(store.continueInChat(session, saying: "Fix the thumb", from: "the iPhone", chat: "chat-from-the-iphone"))
        #expect(chat == "chat-from-the-iphone")
        #expect(host.chats[chat]?.continues == session)
        #expect(host.chats[chat]?.folder == folder.path)
        #expect(host.chats[chat]?.items.first?.text == "Rig the glove for the fighter")
        #expect(await eventually { host.chats[chat]?.items.contains { $0.kind == .user && $0.text == "Fix the thumb" } == true })
        // The session it came from stops asking, and the timeline says where it went.
        #expect(store.session(session)?.state == .idle)
        #expect(store.session(session)?.ask == nil)
        #expect(store[TestBoard.projectID]?.events.first?.title == "Carried on in Software Factory, from the iPhone")
        // Answering again goes to the same chat.
        #expect(store.continueInChat(session, saying: "And the elbow", from: "the iPhone", chat: chat) == chat)

        if let ask = host.chats[chat]?.ask { desk.settle(ask.id, with: PermissionDesk.Answer(allow: false, from: "this Mac")) }
        host.stop(chat)
        #expect(await eventually { !host.isHosting(chat) })
    }

    @Test func noClaudeSaysSo() throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["FactoryClaudePath"] = "/nowhere/claude"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            arguments["FactoryClaudePath"] = nil
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let project = Project(id: "moth-radio", name: "Moth Radio", path: TestBoard.folder.path)
        let id = try #require(host.newChat(in: project))
        // Without a claude here, or with one where the stand-in looked: either way it says why.
        if SessionHost.claudePath() == nil {
            #expect(!host.send("Hello", to: id))
            #expect(host.chats[id]?.status == .failed)
            #expect(host.chats[id]?.problem != nil)
        }
    }
}
