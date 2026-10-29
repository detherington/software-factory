import Foundation
import Testing

/// What the iPhone writes to the inbox, folded into the board as a Mac does it, and what the
/// iPhone gets of the board.
@MainActor
@Suite("Changes from the iPhone")
struct PhoneChangeTests {
    let store = TestBoard.make()

    init() {
        store.hook("UserPromptSubmit", UUID().uuidString, ["prompt": "Fix the page turn"])
    }

    private func todoChange(_ todo: Todo, project: String = TestBoard.projectID, name: String? = "Moth Radio") -> CloudBoard.Change {
        CloudBoard.Change(kind: .todo, project: project, projectName: name, todo: todo)
    }

    private func fold(_ change: CloudBoard.Change, now: Date = .now) -> Bool {
        PhoneShare.fold(change, into: store, digests: DigestStore.shared, now: now)
    }

    @Test func aTodoAddedOnThePhoneJoinsTheBoard() {
        let now = Date.now
        let todo = Todo(text: "Added on the iPhone", created: now, updated: now)
        #expect(fold(todoChange(todo)))
        #expect(store[TestBoard.projectID]?.openTodos.map(\.text) == ["Added on the iPhone"])
    }

    @Test func aTickOnThePhoneIsLogged() {
        let now = Date.now
        var todo = Todo(text: "Rename the export button", created: now.addingTimeInterval(-60), updated: now.addingTimeInterval(-60))
        #expect(fold(todoChange(todo)))
        todo.done = true
        todo.updated = now
        todo.completed = now
        #expect(fold(todoChange(todo)))
        #expect(store[TestBoard.projectID]?.openTodos.isEmpty == true)
        #expect(store[TestBoard.projectID]?.events.first?.title == "Rename the export button")
        #expect(store[TestBoard.projectID]?.events.first?.state == .done)
    }

    @Test func anOlderChangeIsLetGo() {
        let now = Date.now
        let todo = Todo(text: "Rename the export button", created: now.addingTimeInterval(-60), updated: now)
        #expect(fold(todoChange(todo)))
        var stale = todo
        stale.text = "Rename the button"
        stale.updated = now.addingTimeInterval(-30)
        #expect(fold(todoChange(stale)))
        #expect(store[TestBoard.projectID]?.openTodos.map(\.text) == ["Rename the export button"])
    }

    /// The phone names a project by the id it has, which may be another Mac's: its name finds it here.
    @Test func anotherMacsProjectIdFindsItByName() {
        let now = Date.now
        let todo = Todo(text: "Added on the iPhone", created: now, updated: now)
        #expect(fold(todoChange(todo, project: "moth-radio-2", name: "Moth Radio")))
        #expect(store[TestBoard.projectID]?.openTodos.count == 1)
    }

    /// A to-do for a project this Mac hasn't heard of waits for a Mac that has, for a day.
    @Test func aTodoForAnUnknownProjectWaits() {
        let now = Date.now
        let todo = Todo(text: "Added on the iPhone", created: now, updated: now)
        #expect(!fold(todoChange(todo, project: "kiln", name: "Kiln")))
        #expect(fold(todoChange(todo, project: "kiln", name: "Kiln"), now: now.addingTimeInterval(2 * 86_400)))
    }

    @Test func aSnoozeFromThePhoneIsTakenWhenItsLater() {
        let nudge = "loose|test-\(UUID().uuidString)"
        let now = Date.now
        let digests = DigestStore.shared
        _ = fold(CloudBoard.Change(kind: .snooze, nudge: nudge, snooze: DigestState.Snooze(until: now.addingTimeInterval(86_400), set: now)))
        #expect(digests.state.snoozed[nudge]?.set == now)
        // A decision made before it doesn't undo it.
        _ = fold(CloudBoard.Change(kind: .snooze, nudge: nudge, snooze: DigestState.Snooze(until: now, set: now.addingTimeInterval(-60))))
        #expect(digests.state.snoozed[nudge]?.until == now.addingTimeInterval(86_400))
    }

    @Test func aChangeSurvivesTheTripThroughICloud() throws {
        let now = Date.now
        let change = todoChange(Todo(text: "Added on the iPhone", created: now, updated: now))
        let record = try CloudBoard.record(for: change)
        let data = try #require(record["data"] as? Data)
        let back = try #require(CloudBoard.decode(CloudBoard.Change.self, from: data))
        #expect(back.kind == .todo)
        #expect(back.todo?.text == "Added on the iPhone")
        #expect(back.projectName == "Moth Radio")
    }

    /// The iPhone gets no folder paths or transcripts, and only so much timeline, but does get each
    /// session's Remote Control link.
    @Test func thePhonesCopyLeavesThingsOut() {
        let now = Date.now
        var project = Project(id: "moth-radio", name: "Moth Radio", path: "/Factory Tests/Moth Radio", now: now)
        project.events = (0..<40).map { Event(date: now.addingTimeInterval(Double(-$0)), title: "Event \($0)") }
        project.sessions = (0..<9).map {
            Session(id: "s\($0)", state: .idle, transcript: "/Users/someone/.claude/projects/x.jsonl", remoteControl: "session_01Link\($0)",
                    steps: [], started: now, updated: now.addingTimeInterval(Double(-$0)), since: now)
        }
        project.todos = [Todo(text: "Kept", created: now, updated: now), Todo(text: "Gone", created: now, updated: now, deleted: true)]
        let copy = CloudBoard.phoneCopy(project)
        #expect(copy.path == nil)
        #expect(copy.events.count == 25)
        #expect(copy.sessions.map(\.id) == ["s0", "s1", "s2", "s3", "s4", "s5"])
        #expect(copy.sessions.allSatisfy { $0.transcript == nil })
        #expect(copy.sessions.first?.remoteControl == "session_01Link0")
        #expect(copy.todos?.map(\.text) == ["Kept"])
    }
}
