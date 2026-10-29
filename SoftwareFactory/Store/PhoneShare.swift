import CloudKit
import CoreGraphics
import Foundation
import Observation
import OSLog
import Security

/// Sends the board to the iPhone app through your private iCloud database (see `CloudBoard`): each
/// project that changed, a few seconds after it changed, and deletes the ones that left the board.
/// When something needs you and you're away from every Mac, it saves an alert, which the iPhone
/// shows as a notification.
///
/// Only a copy signed with the team carries the iCloud entitlement; one signed locally (a Mac that
/// can't sign with the team) leaves this off.
@MainActor
@Observable
final class PhoneShare {
    static let shared = PhoneShare()

    enum Status: Equatable {
        case off
        /// Signed without iCloud, or no iCloud account: why.
        case unavailable(String)
        case starting
        case shared(Date, count: Int)
        case failed(String)
    }

    var isOn = UserDefaults.standard.object(forKey: "FactoryPhone") == nil || UserDefaults.standard.bool(forKey: "FactoryPhone") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "FactoryPhone")
            isOn ? start() : stop()
        }
    }
    var sendsAlerts = UserDefaults.standard.object(forKey: "FactoryPhoneAlerts") == nil || UserDefaults.standard.bool(forKey: "FactoryPhoneAlerts") {
        didSet { UserDefaults.standard.set(sendsAlerts, forKey: "FactoryPhoneAlerts") }
    }
    private(set) var status: Status = .off

    /// How long something waits before the iPhone hears of it, and how long you must have been away.
    static let alertDelay: TimeInterval = 120
    static let awayAfter: TimeInterval = 300

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var firstChange: Date?
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private var zoneReady = false
    @ObservationIgnored private var hasAlertsSubscription = false
    /// What's in iCloud now, by project: the data last sent. Read from iCloud on the first send.
    @ObservationIgnored private var sent: [String: Data]?
    @ObservationIgnored private var state = Saved()
    @ObservationIgnored private var otherMacsInput: Date?
    @ObservationIgnored private var lastPresenceWrite = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "com.darrell.softwarefactory", category: "phone")
    /// `-FactoryPhoneIgnoresPresence YES`: alert as if you were away from every Mac (for testing).
    @ObservationIgnored private let ignoresPresence = UserDefaults.standard.bool(forKey: "FactoryPhoneIgnoresPresence")

    /// The alerts this Mac saved, kept a day so they can be cleared away.
    private struct Saved: Codable {
        var alerts: [String: Date] = [:]
    }

    private var fileURL: URL { ProjectStore.shared.dataDirectory.appending(path: "phone.json") }

    // The board is made first and tells this when it changes, so nothing here may reach for the
    // board before `start()`.
    private func load() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? ProjectStore.decoder.decode(Saved.self, from: data) {
            state = saved
        }
    }

    /// Whether this copy was signed with iCloud: one signed locally would be stopped by macOS at its
    /// first CloudKit call.
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String] else {
            return false
        }
        return services.contains("CloudKit")
    }()

    private var database: CKDatabase? { Self.isEntitled ? CloudBoard.container?.privateCloudDatabase : nil }

    // MARK: - Starting

    func start() {
        guard isOn else { status = .off; return }
        guard Self.isEntitled, CloudBoard.container != nil else {
            status = .unavailable(String(localized: "This copy was signed without iCloud. scripts/install.sh signs it with your team when Xcode can."))
            return
        }
        guard loop == nil else { return }
        status = .starting
        load()
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        pending?.cancel()
        pending = nil
        status = .off
    }

    /// The board changed: send it within ten seconds, and at least every thirty while it keeps changing.
    func boardChanged() {
        guard isOn, loop != nil else { return }
        let now = Date.now
        if firstChange == nil { firstChange = now }
        pending?.cancel()
        let wait = min(10, max(0, 30 - now.timeIntervalSince(firstChange ?? now)))
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.send()
        }
    }

    private func tick() async {
        guard let container = CloudBoard.container else { return }
        if case .starting = status {
            let account = (try? await container.accountStatus()) ?? .couldNotDetermine
            guard account == .available else {
                status = .unavailable(String(localized: "Sign in to iCloud in System Settings to see the board on your iPhone."))
                return
            }
        }
        await send()
        await sharePresence()
        if sendsAlerts {
            await subscribeToAlerts()
            await sendAlerts()
        }
        await clearOldAlerts()
    }

    // MARK: - Projects

    private func send() async {
        guard let database, !isSending else { return }
        isSending = true
        firstChange = nil
        defer { isSending = false }
        do {
            if !zoneReady {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: CloudBoard.zoneID)], deleting: [])
                zoneReady = true
            }
            if sent == nil { sent = try await readSent(from: database) }
            let store = ProjectStore.shared
            let board = store.projects.values.filter { !$0.hidden }
            var payloads: [String: Data] = [:]
            for project in board {
                payloads[project.id] = try CloudBoard.encode(CloudBoard.phoneCopy(project))
            }
            let changed = board.filter { payloads[$0.id] != sent?[$0.id] }
            let gone = Set((sent ?? [:]).keys).subtracting(payloads.keys)
            if !changed.isEmpty || !gone.isEmpty {
                let records = changed.map { CloudBoard.record(payloads[$0.id]!, for: $0, machine: store.machineName) }
                // Saved in batches: CloudKit takes up to 400 records, or 2 MB, a request.
                for batch in records.chunked(into: 50) {
                    _ = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys, atomically: false)
                }
                if !gone.isEmpty {
                    _ = try await database.modifyRecords(saving: [], deleting: gone.map(CloudBoard.recordID(for:)), atomically: false)
                }
                for project in changed { sent?[project.id] = payloads[project.id] }
                for id in gone { sent?[id] = nil }
            }
            status = .shared(.now, count: payloads.count)
        } catch {
            log.error("Couldn't send the board: \(error.localizedDescription, privacy: .public)")
            status = .failed(Self.describe(error))
            // Read what's there again next time, in case some of it went.
            sent = nil
        }
    }

    /// What iCloud has now, so a restart doesn't send every project again.
    private func readSent(from database: CKDatabase) async throws -> [String: Data] {
        var found: [String: Data] = [:]
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: CloudBoard.zoneID, since: token)
            for case .success(let modification) in changes.modificationResultsByID.values {
                found[modification.record.recordID.recordName] = modification.record[CloudBoard.Field.data] as? Data ?? Data()
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return found
    }

    // MARK: - Alerts

    /// Saves an alert for each thing that has needed you for two minutes while you've been away from
    /// every Mac for five. Each is named for what it's about, so two Macs saving it make one alert.
    private func sendAlerts() async {
        guard let database else { return }
        let now = Date.now
        let lastInput = [now.addingTimeInterval(-Presence.secondsSinceInput), otherMacsInput].compactMap { $0 }.max() ?? now
        guard ignoresPresence || now.timeIntervalSince(lastInput) >= Self.awayAfter else { return }
        let store = ProjectStore.shared
        var alerts: [CKRecord] = []
        for project in store.projects.values where !project.hidden {
            for session in project.liveSessions(at: now) where [.waiting, .yourCall, .blocked].contains(session.state) {
                guard now.timeIntervalSince(session.since) >= Self.alertDelay else { continue }
                let id = "\(session.id).\(session.state.rawValue).\(Int(session.since.timeIntervalSince1970))"
                guard state.alerts[id] == nil else { continue }
                let (title, body) = Self.text(for: session.state, project: project, session: session)
                alerts.append(CloudBoard.alert(id: id, title: title, body: body, project: project.id))
            }
            if project.reported == .blocked, now.timeIntervalSince(project.reportedAt) >= Self.alertDelay,
               now.timeIntervalSince(project.reportedAt) < 86_400 {
                let id = "\(project.id).blocked.\(Int(project.reportedAt.timeIntervalSince1970))"
                if state.alerts[id] == nil {
                    let (title, body) = Self.text(for: .blocked, project: project, session: nil)
                    alerts.append(CloudBoard.alert(id: id, title: title, body: body, project: project.id))
                }
            }
        }
        guard !alerts.isEmpty else { return }
        do {
            // Only new records notify. One that another Mac saved first comes back as changed, which
            // means it's been sent; anything else is tried again next time.
            let (saved, _) = try await database.modifyRecords(saving: alerts, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (id, result) in saved {
                switch result {
                case .success: state.alerts[id.recordName] = now
                case .failure(let error):
                    if (error as? CKError)?.code == .serverRecordChanged { state.alerts[id.recordName] = now }
                    else { log.error("Couldn't send an alert: \(error.localizedDescription, privacy: .public)") }
                }
            }
            save()
        } catch {
            log.error("Couldn't send alerts: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Makes the iPhone's alerts subscription when it's missing. The iPhone app makes it too, but
    /// iCloud has refused the iPhone's save while taking the Mac's; either works, since a subscription
    /// belongs to the iCloud account, not the device that made it.
    private func subscribeToAlerts() async {
        guard let database, !hasAlertsSubscription else { return }
        guard let subscriptions = try? await database.allSubscriptions() else { return }
        if subscriptions.contains(where: { $0.subscriptionID == CloudBoard.alertSubscription }) {
            hasAlertsSubscription = true
            return
        }
        do {
            let (saved, _) = try await database.modifySubscriptions(saving: [CloudBoard.alertsSubscription()], deleting: [])
            if case .success = saved[CloudBoard.alertSubscription] { hasAlertsSubscription = true }
        } catch {
            log.error("Couldn't subscribe the iPhone to alerts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func text(for state: ProjectState, project: Project, session: Session?) -> (String, String) {
        let name = project.name
        switch state {
        case .yourCall: return (String(localized: "\(name): your call"), session?.ask ?? session?.message ?? "")
        case .blocked: return (String(localized: "\(name) is blocked"), session?.message ?? project.note ?? "")
        default: return (String(localized: "\(name) needs you"), session?.message ?? session?.task ?? "")
        }
    }

    private func clearOldAlerts() async {
        guard let database else { return }
        let old = state.alerts.filter { Date.now.timeIntervalSince($0.value) > 86_400 }.map(\.key)
        guard !old.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: old.map { CKRecord.ID(recordName: $0) }, atomically: false)
        for id in old { state.alerts[id] = nil }
        save()
    }

    // MARK: - Away from every Mac

    /// Shares when you last used this Mac (iCloud Drive/Software Factory/Presence), and reads when
    /// you last used the others, so the iPhone isn't alerted while you're at one of them.
    private func sharePresence() async {
        let store = ProjectStore.shared
        guard store.syncsWithOtherMacs, SyncFolder.isAvailable else { otherMacsInput = nil; return }
        let now = Date.now
        let lastInput = now.addingTimeInterval(-Presence.secondsSinceInput)
        let machineID = store.machineID
        let write = lastInput.timeIntervalSince(lastPresenceWrite) > 60
        if write { lastPresenceWrite = lastInput }
        otherMacsInput = await Task.detached(priority: .utility) {
            if write { try? SyncFolder.writeShared(Presence.Mark(lastInput: lastInput), in: "Presence", machineID: machineID) }
            return SyncFolder.readShared(Presence.Mark.self, in: "Presence", excluding: machineID).map(\.lastInput).max()
        }.value
    }

    #if DEBUG
    /// Reads the board back and lists the subscriptions; `testAlert` saves an alert the iPhone should
    /// show, and `forget` deletes a record by name (a test alert, after).
    func debugCheck(testAlert: Bool = false, forget: String? = nil) async -> [String: String] {
        guard let database else { return ["error": "not entitled"] }
        var result: [String: String] = ["status": "\(status)"]
        do {
            result["projects"] = "\(try await CloudBoard.fetchProjects(from: database).count)"
        } catch {
            result["read"] = "\(error)"
        }
        if let subscriptions = try? await database.allSubscriptions() {
            result["subscriptions"] = subscriptions.map(\.subscriptionID).sorted().joined(separator: ", ")
        }
        if testAlert {
            let record = CloudBoard.alert(id: "test-alert-\(Int(Date.now.timeIntervalSince1970))", title: "Software Factory: a test alert",
                                          body: "If this is on your iPhone, alerts work.", project: "software-factory")
            result["testAlert"] = (try? await database.save(record)).map { "saved \($0.recordID.recordName)" } ?? "not saved"
        }
        if let forget {
            result["forget"] = (try? await database.deleteRecord(withID: CKRecord.ID(recordName: forget))) == nil ? "not deleted" : "deleted"
        }
        return result
    }
    #endif

    // MARK: -

    private func save() {
        do {
            try ProjectStore.encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save phone.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated: return String(localized: "Sign in to iCloud in System Settings.")
        case .networkUnavailable, .networkFailure: return String(localized: "No connection to iCloud.")
        case .quotaExceeded: return String(localized: "Your iCloud storage is full.")
        default:
            // Before the schema is deployed, production refuses the new record types.
            if error.localizedDescription.localizedCaseInsensitiveContains("schema") || error.code == .serverRejectedRequest {
                return String(localized: "iCloud doesn't know the board's records yet: deploy the CloudKit schema (README › iPhone).")
            }
            return error.localizedDescription
        }
    }
}

/// When you last used a Mac.
nonisolated enum Presence {
    struct Mark: Codable, Sendable {
        var lastInput: Date
    }

    /// Seconds since the last mouse or keyboard input on this Mac. No permission is needed to ask.
    static var secondsSinceInput: Double {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
