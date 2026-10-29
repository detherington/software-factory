import Foundation

/// Boards shared through iCloud Drive: each Mac writes its own projects to
/// iCloud Drive/Software Factory/Boards/<machine id>.json and reads the others'. A Mac only ever
/// writes its own file, so there's nothing to conflict. No entitlement is needed: to a Mac app that
/// isn't sandboxed, iCloud Drive is a folder.
nonisolated enum SyncFolder {
    /// One Mac's board, as it shares it.
    struct Board: Codable, Sendable {
        var version = 1
        var machineID: String
        var machineName: String
        var updated: Date
        var projects: [Project]
    }

    /// Another Mac's board file, and when it last changed.
    struct Peer: Sendable {
        var machineID: String
        var modified: Date
        var board: Board?
    }

    static var iCloudDrive: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }

    /// A folder in place of iCloud Drive's (`-FactorySyncFolder`), for testing two boards on one Mac.
    private static var override: URL? {
        UserDefaults.standard.string(forKey: "FactorySyncFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var isAvailable: Bool { override != nil || FileManager.default.fileExists(atPath: iCloudDrive.path) }

    static var folder: URL { override ?? iCloudDrive.appending(path: "Software Factory/Boards", directoryHint: .isDirectory) }

    /// A folder beside the boards where each Mac keeps one file of its own, named by its id:
    /// "Stats" for the Passport's numbers, "Prompts" for saved prompts.
    static func sharedFolder(_ name: String) -> URL {
        folder.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
    }

    static func writeShared<T: Encodable>(_ value: T, in name: String, machineID: String) throws {
        let directory = sharedFolder(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let url = directory.appending(path: "\(machineID).json")
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do { try data.write(to: url, options: .atomic) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// The other Macs' files in a shared folder. iCloud Drive is asked to download any it has only a
    /// placeholder for; they're read next time.
    static func readShared<T: Decodable>(_ type: T.Type, in name: String, excluding machineID: String) -> [T] {
        let directory = sharedFolder(name)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file in
            var name = file.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(at: directory.appending(path: name))
                return nil
            }
            guard name.hasSuffix(".json"), name.dropLast(".json".count) != machineID else { return nil }
            var value: T?
            var coordination: NSError?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordination) { url in
                value = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(T.self, from: $0) }
            }
            return value
        }
    }

    static func write(_ board: Board) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder.encode(board)
        let url = folder.appending(path: "\(board.machineID).json")
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in
            do { try data.write(to: url, options: .atomic) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// The other Macs' board files. Each is read only if it changed since `known`; iCloud Drive is
    /// asked to download any it has only a placeholder for.
    static func peers(excluding machineID: String, known: [String: Date]) -> [Peer] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        return files.compactMap { file -> Peer? in
            // iCloud Drive shows a file it hasn't downloaded as ".<name>.icloud".
            var name = file.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appending(path: name))
                return nil
            }
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(".json".count))
            guard id != machineID, let modified = try? file.resourceValues(forKeys: keys).contentModificationDate else { return nil }
            guard known[id] != modified else { return Peer(machineID: id, modified: modified, board: nil) }
            return Peer(machineID: id, modified: modified, board: read(file))
        }
    }

    private static func read(_ url: URL) -> Board? {
        var board: Board?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            board = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Board.self, from: $0) }
        }
        return board
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONDates.encoding
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONDates.decoding
        return decoder
    }()
}
