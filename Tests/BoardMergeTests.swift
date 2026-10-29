import Foundation
import Testing

/// One project's records from several Macs, made into one card.
@Suite("Merging boards")
struct BoardMergeTests {
    let now = Date.now
    let thisMac = TestBoard.thisMac

    private func project(_ change: (inout Project) -> Void = { _ in }) -> Project {
        var project = Project(id: "moth-radio", name: "Moth Radio", path: "/Factory Tests/Moth Radio", now: now)
        change(&project)
        return project
    }

    private func session(_ id: String, _ state: ProjectState, machine: String? = nil, updated: Date? = nil) -> Session {
        Session(id: id, state: state, machine: machine, steps: [], started: now, updated: updated ?? now, since: now)
    }

    private func todo(_ id: UUID, _ text: String, updated: Date, done: Bool = false, deleted: Bool = false) -> Todo {
        Todo(id: id, text: text, done: done, created: now.addingTimeInterval(-86_400), updated: updated, deleted: deleted)
    }

    /// A stray second board claiming Ratatoskr, and Ratatoskr's copy of this Mac's loose ends: each
    /// Mac's still shows once.
    @Test func eachMacsLooseEndsShowOnce() throws {
        let mine = project { $0.looseEnds = [LooseEnds(changes: 2, unpushed: 0)] }
        let theirs = project { $0.looseEnds = [LooseEnds(changes: 4, unpushed: 1), LooseEnds(changes: 2, unpushed: 0, machine: thisMac)] }
        let merged = try #require(BoardMerge.combine(mine, [(theirs, "Ratatoskr"), (theirs, "Ratatoskr")], thisMac: thisMac))
        #expect(merged.openLooseEnds.count == 2)
        #expect(merged.openLooseEnds.filter { $0.machine == nil }.map(\.changes) == [2])
        #expect(merged.openLooseEnds.filter { $0.machine == "Ratatoskr" }.map(\.changes) == [4])
    }

    @Test func anotherMacsSessionsCarryItsName() throws {
        let mine = project { $0.sessions = [session("here", .working)] }
        // Ratatoskr's board has its own session, and this Mac's, heard over the network.
        let theirs = project { $0.sessions = [session("there", .yourCall), session("here", .idle, machine: thisMac)] }
        let merged = try #require(BoardMerge.combine(mine, [(theirs, "Ratatoskr")], thisMac: thisMac))
        #expect(merged.sessions.count == 2)
        #expect(merged.sessions.first { $0.id == "there" }?.machine == "Ratatoskr")
        #expect(merged.sessions.first { $0.id == "here" }?.state == .working)
        #expect(merged.state(at: now) == .yourCall)
    }

    @Test func theSameSessionTwiceKeepsTheNewer() throws {
        let mine = project { $0.sessions = [session("s", .working, machine: "Ratatoskr", updated: now.addingTimeInterval(-60))] }
        let theirs = project { $0.sessions = [session("s", .waiting, updated: now)] }
        let merged = try #require(BoardMerge.combine(mine, [(theirs, "Ratatoskr")], thisMac: thisMac))
        #expect(merged.sessions.map(\.state) == [.waiting])
    }

    @Test func theLatestChangeToATodoWins() throws {
        let id = UUID()
        let mine = project { $0.todos = [todo(id, "Rename the export button", updated: now.addingTimeInterval(-60))] }
        let ticked = project { $0.todos = [todo(id, "Rename the export button", updated: now, done: true)] }
        #expect(try #require(BoardMerge.combine(mine, [(ticked, "Ratatoskr")], thisMac: thisMac)).openTodos.isEmpty)

        let older = project { $0.todos = [todo(id, "Rename the button", updated: now.addingTimeInterval(-120), done: true)] }
        let merged = try #require(BoardMerge.combine(mine, [(older, "Ratatoskr")], thisMac: thisMac))
        #expect(merged.openTodos.map(\.text) == ["Rename the export button"])
    }

    /// Two Macs changing a to-do at the same moment make the same pick: a deletion, then a tick, then
    /// the text.
    @Test func aTieIsBrokenTheSameWayEverywhere() {
        let id = UUID()
        let plain = todo(id, "A", updated: now)
        let done = todo(id, "A", updated: now, done: true)
        let deleted = todo(id, "A", updated: now, deleted: true)
        #expect(deleted.supersedes(done) && !done.supersedes(deleted))
        #expect(done.supersedes(plain) && !plain.supersedes(done))
        #expect(todo(id, "B", updated: now).supersedes(plain) != plain.supersedes(todo(id, "B", updated: now)))
    }

    @Test func theLatestReportWins() throws {
        let mine = project {
            $0.task = "Old task"
            $0.milestone = "0.2"
            $0.lastReport = now.addingTimeInterval(-600)
        }
        let theirs = project {
            $0.task = "Ship 0.3"
            $0.milestone = "0.3"
            $0.lastReport = now
        }
        let merged = try #require(BoardMerge.combine(mine, [(theirs, "Ratatoskr")], thisMac: thisMac))
        #expect(merged.task == "Ship 0.3")
        #expect(merged.milestone == "0.3")
        #expect(merged.path == "/Factory Tests/Moth Radio")
    }

    @Test func aProjectOnlyAnotherMacHasIsTheirs() throws {
        let theirs = project { $0.sessions = [session("there", .working)] }
        let merged = try #require(BoardMerge.combine(nil, [(theirs, "Ratatoskr")], thisMac: thisMac))
        #expect(merged.sessions.first?.machine == "Ratatoskr")
    }
}
