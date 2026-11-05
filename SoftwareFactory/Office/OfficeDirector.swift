import Foundation
import Observation

/// Runs the office while it's on screen: every five seconds it reads the board (and, off the main
/// thread, the agents' files and this Mac's machines) into an `OfficeState`; every second in between
/// it lets the cast move held states on. Demo mode swaps in `OfficeDemo`'s made-up office, with a
/// cast of its own, so the live one is never touched by it.
@MainActor
@Observable
final class OfficeDirector {
    static let shared = OfficeDirector()

    static let refreshInterval: TimeInterval = 5

    var isDemo = false {
        didSet { if isDemo != oldValue { restart() } }
    }
    private(set) var state = OfficeState.empty
    private(set) var cast = OfficeCast()
    private(set) var stage = OfficeStage()
    /// When the office last read the board.
    private(set) var lastRefresh: Date?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var machineMemory = OfficeMachines()
    @ObservationIgnored private var simulators: [OfficeScan.Simulator] = []
    @ObservationIgnored private var simulatorsRead = Date.distantPast
    @ObservationIgnored private var demoTick = 0
    @ObservationIgnored private let store: ProjectStore

    init(store: ProjectStore = .shared) {
        self.store = store
    }

    /// Your first name, for the owner's name tag; "You" in the demo, which is for screenshots.
    var ownerName: String {
        if isDemo { return String(localized: "You") }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? String(localized: "You")
    }

    // MARK: Running

    /// The office screen calls this when it appears, and `stop` when it goes.
    func start() {
        watchers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                for _ in 0..<Int(Self.refreshInterval) {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    self?.tick()
                }
            }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    private func restart() {
        cast = OfficeCast()
        stage.reset()
        state = .empty
        lastRefresh = nil
        demoTick = 0
        if loop != nil {
            loop?.cancel()
            loop = nil
            let watching = watchers
            watchers = 0
            for _ in 0..<max(1, watching) { start() }
        }
    }

    func refresh() async {
        let now = Date.now
        let next: OfficeState
        if isDemo {
            next = OfficeDemo.state(tick: demoTick, now: now, projects: Array(store.projects.values), ownerName: ownerName)
            demoTick += 1
        } else {
            let sessions = localSessions(now: now)
            let readSimulators = now.timeIntervalSince(simulatorsRead) > 15
            let scanned = await Task.detached(priority: .utility) {
                (OfficeScan.agents(of: sessions, now: now), OfficeScan.processes(), readSimulators ? OfficeScan.simulators() : nil)
            }.value
            // Demo mode came on while reading: drop it.
            guard !isDemo else { return }
            next = live(agents: scanned.0, processes: scanned.1, simulators: scanned.2, now: now)
        }
        apply(next, now: Date.now)
    }

    /// Reads everything on the main thread at once: for the Debug snapshots.
    func refreshNow(at now: Date = .now) {
        let next = isDemo
            ? OfficeDemo.state(tick: demoTick, now: now, projects: Array(store.projects.values), ownerName: ownerName)
            : live(agents: OfficeScan.agents(of: localSessions(now: now), now: now), processes: OfficeScan.processes(),
                   simulators: OfficeScan.simulators(), now: now)
        if isDemo { demoTick += 1 }
        apply(next, now: now)
    }

    func tick(at now: Date = .now) {
        cast.tick(now: now)
        stage.apply(cast, now: now)
    }

    private func apply(_ next: OfficeState, now: Date) {
        state = next
        cast.update(next, now: now)
        stage.apply(cast, now: now)
        lastRefresh = now
    }

    // MARK: The live office

    /// Sessions on this Mac in the office, with their transcripts: where their agents' files are.
    private func localSessions(now: Date) -> [OfficeScan.SessionFiles] {
        store.projects.values.flatMap { project in
            project.sessions.compactMap { session -> OfficeScan.SessionFiles? in
                guard session.machine == nil, let transcript = session.transcript,
                      now.timeIntervalSince(session.updated) < OfficeMapper.recentWindow + OfficeMapper.agentIdleWindow else { return nil }
                return OfficeScan.SessionFiles(session: session.id, transcript: transcript)
            }
        }
    }

    private func live(agents: [OfficeAgent], processes: (building: Bool, vms: Int), simulators fresh: [OfficeScan.Simulator]?,
                      now: Date) -> OfficeState {
        if let fresh {
            simulators = fresh
            simulatorsRead = now
        }
        let projects = Array(store.projects.values)
        // The other Macs: synced boards, and Macs reporting over the network.
        var remotes: [String: Date?] = [:]
        for board in store.peers.values { remotes[board.machineName] = board.updated }
        for (name, heard) in store.machines { remotes[name] = max(heard, (remotes[name] ?? nil) ?? .distantPast) }
        for project in projects { for session in project.sessions { if let machine = session.machine, remotes[machine] == nil { remotes[machine] = .some(nil) } } }
        remotes[store.machineName] = nil
        let machines = machineMemory.machines(thisMac: store.machineName, building: processes.building, vms: processes.vms,
                                              simulators: simulators, remotes: remotes.map { OfficeMachines.Remote(name: $0.key, heard: $0.value) },
                                              projects: projects, now: now)
        let input = OfficeInput(projects: projects, agents: agents, machines: machines, ownerName: ownerName,
                                lastUsed: PhoneShare.shared.lastUsedAnyMac, secondsSinceInput: Presence.secondsSinceInput, now: now)
        return OfficeMapper.state(from: input)
    }

    // MARK: Reading

    /// People at work, out of everyone (you aside).
    var atWork: (working: Int, total: Int) {
        let staff = cast.staff
        return (staff.filter { $0.shown.isAtWork }.count, staff.count)
    }

    var machinesOn: (on: Int, total: Int) {
        (state.machines.filter(\.isOn).count, state.machines.count)
    }

    /// The latest messages, by name: "Ada → Bram".
    var feed: [(id: String, from: String, to: String, label: String, at: Date)] {
        state.messages.prefix(5).map { message in
            let from = cast.name(of: message.from) ?? message.from
            let to = cast.name(of: message.to) ?? message.to
            return ("\(message.from)>\(message.to)>\(message.at.timeIntervalSince1970)", from, to, message.label, message.at)
        }
    }
}
