import AppKit
import Foundation
import Observation
import OSLog

/// A prompt you send often, kept to start a Claude Desktop chat with: "Ship a build to TestFlight".
/// It belongs to one project, or to every project.
struct SavedPrompt: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var title: String
    var text: String
    /// The project it's for; nil for every project.
    var project: String?
    /// That project's name, to find it on another Mac.
    var projectName: String?
    var updated: Date
    /// Deleted, kept a while so the deletion reaches every Mac.
    var deleted = false

    /// Whether this version wins over another of the same prompt: the later change, a deletion on a tie.
    func supersedes(_ other: SavedPrompt) -> Bool {
        if updated != other.updated { return updated > other.updated }
        if deleted != other.deleted { return deleted }
        return (title, text) > (other.title, other.text)
    }
}

/// Saved prompts, kept in prompts.json and shared with the other Macs through iCloud Drive
/// (Software Factory/Prompts/<machine id>.json): the latest change to each wins, wherever it was made.
@MainActor
@Observable
final class PromptStore {
    static let shared = PromptStore()
    /// The starter that asks Claude about a folder's loose ends, which the Today screen offers.
    static let tidyLooseEnds = UUID(uuidString: "5F0C1E2A-0000-4000-8000-000000000002")!

    private(set) var all: [SavedPrompt] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.darrell.softwarefactory", category: "prompts")

    private struct Saved: Codable {
        var version = 1
        var prompts: [SavedPrompt]
        /// The starter prompts were added once; deleting them keeps them gone.
        var seeded = false
    }

    private var fileURL: URL { ProjectStore.shared.dataDirectory.appending(path: "prompts.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? ProjectStore.decoder.decode(Saved.self, from: data) {
            all = saved.prompts
            if !saved.seeded { seed() }
        } else {
            seed()
        }
    }

    /// Every project's prompts, then this one's own, by title.
    func prompts(for project: Project?) -> (own: [SavedPrompt], everywhere: [SavedPrompt]) {
        let live = all.filter { !$0.deleted }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let own = project.map { project in live.filter { $0.project == project.id } } ?? []
        return (own, live.filter { $0.project == nil })
    }

    func add(title: String, text: String, project: Project?) {
        all.append(SavedPrompt(title: title, text: text, project: project?.id, projectName: project?.name, updated: .now))
        changed()
    }

    func change(_ id: UUID, title: String, text: String, project: Project?) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].title = title
        all[index].text = text
        all[index].project = project?.id
        all[index].projectName = project?.name
        all[index].updated = .now
        changed()
    }

    func delete(_ id: UUID) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].deleted = true
        all[index].updated = .now
        changed()
    }

    /// Opens a new Claude Desktop chat in the project's folder with the prompt typed in, not sent.
    func start(_ prompt: SavedPrompt, in project: Project) {
        guard let path = project.path, project.isOnThisMac else { return }
        Reveal.newChat(in: path, prompt: prompt.text)
    }

    // MARK: - Other Macs

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.readOtherMacs()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func readOtherMacs() async {
        let store = ProjectStore.shared
        guard store.syncsWithOtherMacs, SyncFolder.isAvailable else { return }
        let machineID = store.machineID
        let theirs = await Task.detached(priority: .utility) {
            SyncFolder.readShared([SavedPrompt].self, in: "Prompts", excluding: machineID)
        }.value
        var merged = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for list in theirs {
            for prompt in list where merged[prompt.id].map(prompt.supersedes) ?? true {
                var prompt = prompt
                // Their project, as it's known here.
                if let id = prompt.project, let name = prompt.projectName {
                    prompt.project = store.projectID(matching: id, name: name, repo: nil)
                }
                merged[prompt.id] = prompt
                changed = true
            }
        }
        guard changed else { return }
        all = Array(merged.values)
        save(share: false)
    }

    // MARK: - Saving

    private func changed() {
        save(share: true)
    }

    private func save(share: Bool) {
        // Deletions are kept 30 days: long enough to reach every Mac.
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        all.removeAll { $0.deleted && $0.updated < cutoff }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectStore.encoder.encode(Saved(prompts: all.sorted { $0.id.uuidString < $1.id.uuidString }, seeded: true))
                .write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save the prompts: \(error.localizedDescription, privacy: .public)")
        }
        guard share else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let store = ProjectStore.shared
            guard store.syncsWithOtherMacs, SyncFolder.isAvailable else { return }
            let (prompts, machineID) = (all, store.machineID)
            await Task.detached(priority: .utility) {
                try? SyncFolder.writeShared(prompts, in: "Prompts", machineID: machineID)
            }.value
        }
    }

    /// A few to start with, for every project. Their ids and dates are fixed, so each Mac's are the
    /// same prompts, and any change or deletion wins over them.
    private func seed() {
        let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
        let starters = [
            ("5F0C1E2A-0000-4000-8000-000000000001", String(localized: "Commit and push"),
             String(localized: "Commit what's done here with a clear message, and push it to GitHub.")),
            ("5F0C1E2A-0000-4000-8000-000000000002", String(localized: "Tidy loose ends"),
             String(localized: "Look at the uncommitted changes and unpushed commits here. Tell me what each is and what you'd do with it.")),
            ("5F0C1E2A-0000-4000-8000-000000000003", String(localized: "What's next?"),
             String(localized: "Look at the README, recent commits and open to-dos here, and suggest what to do next.")),
        ]
        for (id, title, text) in starters {
            guard let uuid = UUID(uuidString: id), !all.contains(where: { $0.id == uuid }) else { continue }
            all.append(SavedPrompt(id: uuid, title: title, text: text, updated: start))
        }
        save(share: false)
    }
}
