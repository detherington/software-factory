import Foundation

/// The last board fetched from iCloud, in the app group's container, where the iPhone app leaves it
/// for its widgets (and finds it again at launch).
nonisolated enum BoardCache {
    struct Saved: Codable, Sendable {
        var projects: [Project]
        var fetched: Date
        var digest: Digest?
        var passport: CloudBoard.Passport?
    }

    private static var url: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FactoryAppGroup") as? String,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return folder.appending(path: "board.json")
    }

    static func read() -> Saved? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONDates.decoding
        return try? decoder.decode(Saved.self, from: data)
    }

    static func write(_ saved: Saved) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONDates.encoding
        try? encoder.encode(saved).write(to: url, options: .atomic)
    }
}

extension Array where Element == Project {
    /// Board order, as on the Mac: what needs you first, then what's live, then by last sign of life.
    func board(at now: Date) -> [Project] {
        filter { !$0.hidden }.sorted { a, b in
            let (sa, sb) = (a.state(at: now), b.state(at: now))
            if sa.isLive != sb.isLive { return sa.isLive }
            if sa.isLive, sa.rank != sb.rank { return sa.rank < sb.rank }
            return a.lastActivity > b.lastActivity
        }
    }

    func count(_ state: ProjectState, at now: Date) -> Int {
        filter { !$0.hidden && $0.state(at: now) == state }.count
    }
}
