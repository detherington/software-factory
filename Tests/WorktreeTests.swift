import Foundation
import Testing

/// Worktrees: which one a session runs in, wherever it is, and each one's branch and loose ends.
@MainActor
@Suite("Worktrees")
struct WorktreeTests {
    let now = Date.now

    // MARK: - Naming a session's worktree

    @Test func aClaudeWorktreeIsNamedByItsPath() {
        #expect(ProjectPath.worktree(in: "/Factory Tests/Moth Radio/.claude/worktrees/clever-elbakyan/Sources") == "clever-elbakyan")
        #expect(ProjectPath.namedWorktree(in: "/Factory Tests/Moth Radio/.claude/worktrees/clever-elbakyan") == "clever-elbakyan")
        #expect(ProjectPath.worktree(in: "/Factory Tests/Moth Radio/Sources") == nil)
    }

    /// One made with `git worktree add` outside the repository: its .git file says whose it is.
    @Test func anyLinkedWorktreeIsNamedByItsFolder() throws {
        let place = TestBoard.folder.appending(path: "Linked-\(UUID().uuidString)").path
        let repo = place + "/Moth Radio"
        let linked = place + "/moth-radio-android"
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/.git/worktrees/moth-radio-android", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: linked + "/Sources", withIntermediateDirectories: true)
        try "gitdir: \(repo)/.git/worktrees/moth-radio-android\n".write(toFile: linked + "/.git", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: place) }

        #expect(ProjectPath.worktree(in: linked + "/Sources") == "moth-radio-android")
        #expect(ProjectPath.root(for: linked + "/Sources") == (repo as NSString).standardizingPath)
        #expect(ProjectPath.worktree(in: repo) == nil)
        // Another Mac's path can't be looked at: only a Claude worktree's name says.
        #expect(ProjectPath.namedWorktree(in: linked) == nil)
    }

    @Test func aSessionMovingIntoAWorktreeSaysSo() {
        let store = TestBoard.make()
        let id = UUID().uuidString
        store.hook("UserPromptSubmit", id, ["prompt": "Fix the page turn"])
        #expect(store.session(id)?.worktree == nil)
        store.hook("PostToolUse", id, ["cwd": TestBoard.projectFolder + "/.claude/worktrees/clever-elbakyan", "tool_name": "EnterWorktree"])
        #expect(store.session(id)?.worktree == "clever-elbakyan")
        store.hook("PostToolUse", id, ["tool_name": "ExitWorktree"])
        #expect(store.session(id)?.worktree == nil)
    }

    /// Another Mac's factory command says which repository and worktree its session is in.
    @Test func anotherMacsWorktreeIsNamedByItsFactoryCommand() {
        let store = TestBoard.make()
        store.hook("UserPromptSubmit", UUID().uuidString, ["prompt": "Fix the page turn"])
        let id = UUID().uuidString
        let project = store.applyClaudeHook([
            "hook_event_name": "UserPromptSubmit", "session_id": id, "prompt": "Port it to Android",
            "cwd": "/Users/someone/Code/moth-radio-android",
            "factory_root": "/Users/someone/Code/Moth Radio", "factory_worktree": "moth-radio-android",
        ], machine: "Ratatoskr")
        #expect(project?.id == TestBoard.projectID)
        #expect(store.session(id)?.worktree == "moth-radio-android")
        #expect(store.session(id)?.machine == "Ratatoskr")
    }

    /// The factory command fills its fields in for another Mac's board only; this Mac's board looks for itself.
    @Test func thisMacsBoardIgnoresTheFactoryCommandsFields() {
        let store = TestBoard.make()
        let id = UUID().uuidString
        store.hook("UserPromptSubmit", id, ["prompt": "Fix the page turn", "factory_root": "/Elsewhere/Kiln", "factory_worktree": "kiln-2"])
        #expect(store.session(id)?.worktree == nil)
        #expect(store[TestBoard.projectID]?.sessions.count == 1)
    }

    // MARK: - Each worktree's branch and loose ends

    @Test func eachWorktreeHasItsBranchAndLooseEnds() throws {
        let git = try Git()
        defer { git.cleanUp() }
        try git(["init", "-q", "-b", "main", git.repo])
        try git.commit("README.md", in: git.repo)
        try git(["init", "-q", "--bare", git.origin])
        try git(["-C", git.repo, "remote", "add", "origin", git.origin])
        try git(["-C", git.repo, "push", "-q", "-u", "origin", "main"])
        let feature = git.place + "/moth-radio-android"
        try git(["-C", git.repo, "worktree", "add", "-q", "-b", "android", feature])
        try git.commit("Android.md", in: feature)
        try git.commit("Gradle.md", in: feature)
        try "Edited".write(toFile: feature + "/README.md", atomically: true, encoding: .utf8)
        try "New".write(toFile: feature + "/Notes.md", atomically: true, encoding: .utf8)

        let checkouts = Discovery.checkouts(in: git.repo)
        #expect(checkouts.count == 2)
        let main = try #require(checkouts.first)
        #expect(main.worktree == nil)
        #expect(main.branch == "main")
        #expect(main.isEmpty)
        let android = try #require(checkouts.last)
        #expect(android.worktree == "moth-radio-android")
        #expect(android.branch == "android")
        // A branch never pushed: its commits are on no remote.
        #expect(android.changes == 2)
        #expect(android.unpushed == 2)

        // Merged into the project's own folder, they're its to push, not the worktree's.
        try git(["-C", git.repo, "merge", "-q", "--ff-only", "android"])
        let merged = Discovery.checkouts(in: git.repo)
        #expect(merged.first?.unpushed == 2)
        #expect(merged.last?.unpushed == 0)
    }

    /// Without a remote nothing can be pushed, so nothing is unpushed.
    @Test func aRepositoryWithoutARemoteHasNothingUnpushed() throws {
        let git = try Git()
        defer { git.cleanUp() }
        try git(["init", "-q", "-b", "main", git.repo])
        try git.commit("README.md", in: git.repo)
        let feature = git.place + "/feature"
        try git(["-C", git.repo, "worktree", "add", "-q", "-b", "feature", feature])
        try git.commit("Feature.md", in: feature)
        let checkouts = Discovery.checkouts(in: git.repo)
        #expect(checkouts.map(\.unpushed) == [0, 0])
        #expect(checkouts.map(\.branch) == ["main", "feature"])
    }

    @Test func aWorktreeWhoseFolderIsGoneIsLeftOut() throws {
        let git = try Git()
        defer { git.cleanUp() }
        try git(["init", "-q", "-b", "main", git.repo])
        try git.commit("README.md", in: git.repo)
        let feature = git.place + "/feature"
        try git(["-C", git.repo, "worktree", "add", "-q", "-b", "feature", feature])
        try FileManager.default.removeItem(atPath: feature)
        #expect(Discovery.checkouts(in: git.repo).map(\.worktree) == [nil])
    }

    // MARK: - On the board

    @Test func aChipSaysWhichWorktreeAndMac() {
        #expect(LooseEnds(changes: 1, unpushed: 0, machine: "Ratatoskr", worktree: "clever-elbakyan").place == " in clever-elbakyan on Ratatoskr")
        #expect(LooseEnds(changes: 1, unpushed: 0, worktree: "clever-elbakyan").place == " in clever-elbakyan")
        #expect(LooseEnds(changes: 1, unpushed: 0).place == "")
    }

    @Test func aSessionFindsItsWorktreesBranch() {
        var project = Project(id: "moth-radio", name: "Moth Radio", path: TestBoard.projectFolder, now: now)
        project.looseEnds = [
            LooseEnds(changes: 0, unpushed: 0, branch: "main"),
            LooseEnds(changes: 0, unpushed: 0, worktree: "clever-elbakyan", branch: "claude/clever-elbakyan"),
            LooseEnds(changes: 0, unpushed: 0, machine: "Ratatoskr", worktree: "clever-elbakyan", branch: "claude/elsewhere"),
        ]
        let here = Session(id: "s", state: .working, worktree: "clever-elbakyan", steps: [], started: now, updated: now, since: now)
        var there = here
        there.machine = "Ratatoskr"
        #expect(project.checkout(for: here)?.branch == "claude/clever-elbakyan")
        #expect(project.checkout(for: there)?.branch == "claude/elsewhere")
    }

    /// Each Mac's own folder first, then worktrees with work left in them, then ones with a session.
    @Test func theWorktreesListLeadsWithWhatMatters() {
        var project = Project(id: "moth-radio", name: "Moth Radio", path: TestBoard.projectFolder, now: now)
        project.looseEnds = [
            LooseEnds(changes: 0, unpushed: 0, worktree: "b-clean"),
            LooseEnds(changes: 0, unpushed: 0, worktree: "c-busy"),
            LooseEnds(changes: 3, unpushed: 0, worktree: "d-dirty"),
            LooseEnds(changes: 0, unpushed: 0, machine: "Ratatoskr"),
            LooseEnds(changes: 0, unpushed: 0),
        ]
        project.sessions = [Session(id: "s", state: .working, worktree: "c-busy", steps: [], started: now, updated: now, since: now)]
        #expect(project.checkouts.map { $0.worktree ?? $0.machine ?? "here" } == ["here", "Ratatoskr", "d-dirty", "c-busy", "b-clean"])
    }

    @Test func eachMacsWorktreesShowOnce() throws {
        var mine = Project(id: "moth-radio", name: "Moth Radio", path: TestBoard.projectFolder, now: now)
        mine.looseEnds = [LooseEnds(changes: 1, unpushed: 0), LooseEnds(changes: 2, unpushed: 0, worktree: "a")]
        var theirs = mine
        theirs.looseEnds = [LooseEnds(changes: 3, unpushed: 0), LooseEnds(changes: 4, unpushed: 0, worktree: "b"),
                            LooseEnds(changes: 2, unpushed: 0, machine: TestBoard.thisMac, worktree: "a")]
        let merged = try #require(BoardMerge.combine(mine, [(theirs, "Ratatoskr"), (theirs, "Ratatoskr")], thisMac: TestBoard.thisMac))
        #expect(merged.openLooseEnds.map(\.changes).sorted() == [1, 2, 3, 4])
        #expect(merged.openLooseEnds.first { $0.changes == 4 }?.place == " in b on Ratatoskr")
    }

    /// The iPhone gets the worktrees with work left in them, and the ones its sessions run in.
    @Test func thePhoneGetsTheWorktreesThatMatter() {
        var project = Project(id: "moth-radio", name: "Moth Radio", path: TestBoard.projectFolder, now: now)
        project.looseEnds = [
            LooseEnds(changes: 0, unpushed: 0, branch: "main"),
            LooseEnds(changes: 0, unpushed: 0, worktree: "stale"),
            LooseEnds(changes: 0, unpushed: 0, worktree: "busy"),
            LooseEnds(changes: 0, unpushed: 1, worktree: "unpushed"),
        ]
        project.sessions = [Session(id: "s", state: .working, worktree: "busy", steps: [], started: now, updated: now, since: now)]
        #expect(CloudBoard.phoneCopy(project).looseEnds?.map { $0.worktree ?? "main" } == ["main", "busy", "unpushed"])
    }
}

/// A scratch place for repositories, and git run in it without anyone's settings.
private struct Git {
    let place: String
    var repo: String { place + "/Moth Radio" }
    var origin: String { place + "/origin.git" }

    init() throws {
        place = TestBoard.folder.appending(path: "Git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: place, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: place) }

    func callAsFunction(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
        }
    }

    func commit(_ file: String, in folder: String) throws {
        try file.write(toFile: folder + "/" + file, atomically: true, encoding: .utf8)
        try self(["-C", folder, "add", file])
        try self(["-C", folder, "commit", "-q", "-m", "Add \(file)"])
    }
}
