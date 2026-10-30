import Foundation

/// What every test runs against: settings held in memory and files in a temporary folder of their
/// own, so no test can read or change the app's. UserDefaults' argument domain is never saved, and it
/// wins over everything else, as `-Factory…` launch arguments do.
nonisolated enum TestBoard {
    static let folder: URL = {
        let temporary = FileManager.default.temporaryDirectory
        // Earlier runs' folders go first.
        for old in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("SoftwareFactoryTests-") {
            try? FileManager.default.removeItem(at: old)
        }
        let folder = temporary.appending(path: "SoftwareFactoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder.appending(path: "Chats"), withIntermediateDirectories: true)
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments.merge([
            "FactoryDataDir": folder.appending(path: "Data").path,
            "FactoryDesktopChats": folder.appending(path: "Chats").path,
            "FactorySyncsWithOtherMacs": false,
            // Were syncing ever on, it would go here, not to iCloud Drive.
            "FactorySyncFolder": folder.appending(path: "Sync/Boards").path,
            "FactoryPhone": false,
            "FactoryPhoneAlerts": false,
            "FactoryDigest": false,
            "FactoryAnswersPermissions": true,
            "FactoryMachineID": "test-mac",
            "FactoryMachineName": thisMac,
        ]) { _, new in new }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        precondition(ProjectStore.defaultDirectory.path.hasPrefix(folder.path), "A test must never use the app's own data folder")
        precondition(DesktopChats.folder.path.hasPrefix(folder.path), "A test must never read Claude Desktop's own chats")
        precondition(SyncFolder.folder.path.hasPrefix(folder.path), "A test must never write to iCloud Drive")
        return folder
    }()

    /// This Mac's name on the test boards.
    static let thisMac = "Test Mac"

    /// A folder that's a project but isn't on disk: a session's working directory.
    static let projectFolder = "/Factory Tests/Moth Radio"
    static let projectID = "moth-radio"

    /// A fresh, empty board, saved in a folder of its own.
    @MainActor static func make() -> ProjectStore {
        ProjectStore(dataDirectory: folder.appending(path: "Boards/\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// A Claude Desktop chat's file, as Desktop writes it: the chat's fields, then half a megabyte of
    /// tool settings, then Remote Control's. `remoteControl` is nil to leave its switch unset.
    /// `sessionLast` puts the session's id after the tool settings, out of the head's reach.
    static func writeChat(id: String = "local_\(UUID().uuidString)", session: String, bridges: [String] = [],
                          remoteControl: Bool? = nil, archived: Bool = false, padding: Int = 600_000,
                          sessionLast: Bool = false) throws -> URL {
        let sessionField = #""cliSessionId":"\#(session)","#
        var head = #"{"sessionId":"\#(id)","# + (sessionLast ? "" : sessionField) + #""cwd":"\#(projectFolder)","#
            + #""title":"Fix the page turn","lastActivityAt":1793300000000,"isArchived":\#(archived),"#
        head += #""toolSurfaceSnapshot":""# + String(repeating: "x", count: padding) + #"","#
        var tail = (sessionLast ? sessionField : "") + #""bridgeSessionIds":[\#(bridges.map { "\"\($0)\"" }.joined(separator: ","))]"#
        if let remoteControl { tail += #","remoteControlUserEnabled":\#(remoteControl)"# }
        let file = folder.appending(path: "Chats/\(id).json")
        try Data((head + tail + "}").utf8).write(to: file)
        return file
    }
}

extension ProjectStore {
    /// A Claude Code hook, as Claude Code posts it, for a session in the test project.
    @discardableResult
    func hook(_ event: String, _ session: String, _ fields: [String: Any] = [:]) -> Project? {
        var payload: [String: Any] = ["hook_event_name": event, "session_id": session, "cwd": TestBoard.projectFolder]
        payload.merge(fields) { _, new in new }
        return applyClaudeHook(payload)
    }

    func session(_ id: String) -> Session? {
        self[TestBoard.projectID]?.sessions.first { $0.id == id }
    }
}

/// Waits for something the store does in a task of its own, for up to two seconds.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
