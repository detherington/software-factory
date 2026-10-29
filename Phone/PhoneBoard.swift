import CloudKit
import Observation
import UserNotifications
import WidgetKit

/// The board on the iPhone: fetched from your private iCloud database, where the Macs leave it,
/// when the app opens, when you pull to refresh, and when iCloud says it changed. The widgets read
/// what it fetched last.
@MainActor
@Observable
final class PhoneBoard {
    static let shared = PhoneBoard()

    private(set) var projects: [Project] = []
    private(set) var fetched: Date?
    private(set) var problem: String?
    private(set) var isRefreshing = false
    /// Ticks so relative times and stale sessions move on.
    private(set) var now = Date.now
    /// The project to show: a widget's, or an alert's.
    var opened: String?

    @ObservationIgnored private var clock: Task<Void, Never>?
    /// `-FactorySampleBoard <file>` (Debug): a board from a file instead of iCloud, for looking at
    /// the screens in the Simulator.
    @ObservationIgnored private let sample: String?

    init() {
        #if DEBUG
        sample = UserDefaults.standard.string(forKey: "FactorySampleBoard")
        #else
        sample = nil
        #endif
        if let sample, let data = try? Data(contentsOf: URL(fileURLWithPath: sample)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = JSONDates.decoding
            projects = (try? decoder.decode([Project].self, from: data)) ?? []
            fetched = .now
        } else if let cache = BoardCache.read() {
            projects = cache.projects
            fetched = cache.fetched
        }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.now = .now
            }
        }
    }

    var board: [Project] { projects.board(at: now) }
    var live: [Project] { board.filter { $0.state(at: now).isLive } }
    var resting: [Project] { board.filter { !$0.state(at: now).isLive } }
    func count(_ state: ProjectState) -> Int { projects.count(state, at: now) }
    subscript(id: String) -> Project? { projects.first { $0.id == id } }

    // MARK: - iCloud

    /// Asks to notify, and subscribes to the board's changes (silent) and to alerts (shown).
    func setUp() async {
        guard sample == nil else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard let database = CloudBoard.container?.privateCloudDatabase else { return }
        do {
            // Only what's missing: a Mac makes the alerts subscription too (see PhoneShare).
            let existing = Set(try await database.allSubscriptions().map(\.subscriptionID))
            let missing = [CloudBoard.boardChangesSubscription(), CloudBoard.alertsSubscription()].filter { !existing.contains($0.subscriptionID) }
            if !missing.isEmpty {
                let (saved, _) = try await database.modifySubscriptions(saving: missing, deleting: [])
                // Each is saved, or refused, on its own.
                for case .failure(let error) in saved.values {
                    problem = String(localized: "Alerts couldn't be set up: \(Self.describe(error))")
                }
            }
        } catch {
            problem = String(localized: "Alerts couldn't be set up: \(Self.describe(error))")
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing, sample == nil else { return }
        guard let database = CloudBoard.container?.privateCloudDatabase else {
            problem = String(localized: "This build has no iCloud container.")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            projects = try await CloudBoard.fetchProjects(from: database)
            fetched = .now
            now = .now
            problem = nil
            BoardCache.write(BoardCache.Saved(projects: projects, fetched: fetched!))
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            problem = Self.describe(error)
        }
    }

    /// softwarefactory://project/<id>, from a widget.
    func open(_ url: URL) {
        guard url.scheme == "softwarefactory", url.host() == "project" else { return }
        opened = url.pathComponents.dropFirst().first
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .zoneNotFound, .userDeletedZone:
            return String(localized: "Nothing from your Macs yet. Open Software Factory on a Mac signed in to the same iCloud account.")
        case .notAuthenticated: return String(localized: "Sign in to iCloud in Settings to see your board.")
        case .networkUnavailable, .networkFailure: return String(localized: "No connection to iCloud.")
        default: return error.localizedDescription
        }
    }
}
