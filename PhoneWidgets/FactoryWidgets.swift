import CloudKit
import SwiftUI
import WidgetKit

@main
struct FactoryWidgets: WidgetBundle {
    var body: some Widget {
        BoardWidget()
        NeedsYouWidget()
    }
}

// MARK: - Timeline

/// The board the app fetched last, from the app group; read from iCloud here too when that's more
/// than ten minutes old, since the app isn't always woken when the board changes.
struct BoardProvider: TimelineProvider {
    func placeholder(in context: Context) -> BoardEntry { BoardEntry(date: .now, projects: Self.sample, fetched: .now) }

    func getSnapshot(in context: Context, completion: @escaping (BoardEntry) -> Void) {
        let cache = BoardCache.read()
        completion(BoardEntry(date: .now, projects: cache?.projects ?? (context.isPreview ? Self.sample : []), fetched: cache?.fetched))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BoardEntry>) -> Void) {
        // WidgetKit calls back from any thread; the reply only hands it the timeline.
        let reply = Reply(send: completion)
        Task {
            var cache = BoardCache.read()
            if cache.map({ Date.now.timeIntervalSince($0.fetched) > 600 }) ?? true,
               let database = CloudBoard.container?.privateCloudDatabase,
               let projects = try? await CloudBoard.fetchProjects(from: database) {
                cache = BoardCache.Saved(projects: projects, fetched: .now)
                BoardCache.write(cache!)
            }
            // The same board every five minutes, so times move on and stale sessions drop away.
            let now = Date.now
            let entries = (0..<4).map { step in
                BoardEntry(date: now.addingTimeInterval(Double(step) * 300), projects: cache?.projects ?? [], fetched: cache?.fetched)
            }
            reply.send(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }

    private struct Reply: @unchecked Sendable {
        let send: (Timeline<BoardEntry>) -> Void
    }

    static let sample: [Project] = {
        var emanata = Project(id: "emanata", name: "Emanata", path: nil)
        emanata.reported = .yourCall
        emanata.task = "Upload build 12 to TestFlight now?"
        var rounds = Project(id: "rounds", name: "Rounds", path: nil)
        rounds.reported = .working
        rounds.task = "Wiring up the watch app"
        var writey = Project(id: "writey", name: "Writey", path: nil)
        writey.reported = .done
        writey.note = "Shipped 1.2"
        return [emanata, rounds, writey]
    }()
}

// MARK: - Home screen

/// The board: what needs you, what's under way, and the latest of the rest.
struct BoardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "board", provider: BoardProvider()) { entry in
            BoardWidgetView(entry: entry, family: nil)
                .containerBackground(Switchyard.background, for: .widget)
        }
        .configurationDisplayName("Board")
        .description("What needs you and what's under way, across your projects.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Lock screen

/// How many projects need you, on the Lock Screen.
struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "needs-you", provider: BoardProvider()) { entry in
            NeedsYouView(entry: entry, family: nil)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Needs You")
        .description("How many projects are waiting on you, and which.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

