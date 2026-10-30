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
    nonisolated static let alertDelay: TimeInterval = 120
    nonisolated static let awayAfter: TimeInterval = 300
    /// TestFlight feedback alerts only as the board learns of it: what came while you were at a Mac
    /// was shown there.
    nonisolated static let feedbackAlertWindow: TimeInterval = 900

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var quickInbox: Task<Void, Never>?
    @ObservationIgnored private var firstChange: Date?
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private var zoneReady = false
    @ObservationIgnored private var hasAlertsSubscription = false
    /// What's in iCloud now, by project: the data last sent. Read from iCloud on the first send.
    @ObservationIgnored private var sent: [String: Data]?
    @ObservationIgnored private var sentDigest: Data?
    /// The Passport last sent, without when it was read, which changes with every read.
    @ObservationIgnored private var sentPassport: Data?
    @ObservationIgnored private var state = Saved()
    @ObservationIgnored private var otherMacsInput: Date?
    @ObservationIgnored private var lastPresenceWrite = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "com.darrell.softwarefactory", category: "phone")
    /// `-FactoryPhoneIgnoresPresence YES`: alert, and send the digest, as if you were away from every
    /// Mac (for testing).
    @ObservationIgnored let pretendsAway = UserDefaults.standard.bool(forKey: "FactoryPhoneIgnoresPresence")

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

    /// The board changed: send it within ten seconds, and at least every thirty while it keeps changing;
    /// at once when it's `soon`, as a permission prompt the iPhone can answer is.
    func boardChanged(soon: Bool = false) {
        guard isOn, loop != nil else { return }
        let now = Date.now
        if firstChange == nil { firstChange = now }
        pending?.cancel()
        let wait = soon ? 0 : min(10, max(0, 30 - now.timeIntervalSince(firstChange ?? now)))
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
        await readInbox()
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
            await sendDigest(to: database)
            await sendPassport(to: database)
        } catch {
            log.error("Couldn't send the board: \(error.localizedDescription, privacy: .public)")
            status = .failed(Self.describe(error))
            // Read what's there again next time, in case some of it went.
            sent = nil
        }
    }

    /// Today's digest, as the Today screen shows it, for the iPhone's: apart from the board, so a
    /// refusal (production before its schema has the Digest type) leaves the board's sending alone.
    private func sendDigest(to database: CKDatabase) async {
        guard let digest = try? CloudBoard.encode(DigestStore.shared.digest(now: .now)), digest != sentDigest else { return }
        do {
            _ = try await database.modifyRecords(saving: [CloudBoard.digestRecord(digest)], deleting: [], savePolicy: .allKeys)
            sentDigest = digest
        } catch {
            log.error("Couldn't send the digest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The Passport's three periods, once this Mac has read its transcripts. It goes again when the
    /// numbers change, not each time they're read.
    private func sendPassport(to database: CKDatabase) async {
        let passport = PassportStore.shared
        guard passport.lastRead != nil else { return }
        let now = Date.now
        var value = CloudBoard.Passport(periods: Dictionary(uniqueKeysWithValues: PassportPeriod.allCases.map { ($0.rawValue, passport.summary($0, now: now)) }),
                                        macs: [ProjectStore.shared.machineName] + passport.otherMacs)
        guard let numbers = try? CloudBoard.encode(value), numbers != sentPassport else { return }
        value.read = passport.lastRead
        do {
            _ = try await database.modifyRecords(saving: [CloudBoard.passportRecord(try CloudBoard.encode(value))], deleting: [], savePolicy: .allKeys)
            sentPassport = numbers
        } catch {
            log.error("Couldn't send the Passport: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What iCloud has now, so a restart doesn't send every project again: the projects (the digest
    /// and the Passport are records of their own, not ones to delete).
    private func readSent(from database: CKDatabase) async throws -> [String: Data] {
        var found: [String: Data] = [:]
        for record in try await CloudBoard.allRecords(in: CloudBoard.zoneID, from: database) {
            let data = record[CloudBoard.Field.data] as? Data ?? Data()
            if record.recordID.recordName == CloudBoard.passportRecordName {
                var passport = CloudBoard.decode(CloudBoard.Passport.self, from: data)
                passport?.read = nil
                sentPassport = passport.flatMap { try? CloudBoard.encode($0) }
            } else if record.recordType == CloudBoard.digestType {
                sentDigest = data
            } else {
                found[record.recordID.recordName] = data
            }
        }
        return found
    }

    // MARK: - Alerts

    /// Saves an alert for each thing that has needed you for two minutes while you've been away from
    /// every Mac for five; a permission prompt (which the iPhone can answer from the alert), and a
    /// tester's crash or screenshot, at once.
    /// Each is named for what it's about, so two Macs saving it make one alert.
    private func sendAlerts() async {
        guard let database else { return }
        let now = Date.now
        let lastInput = [now.addingTimeInterval(-Presence.secondsSinceInput), otherMacsInput].compactMap { $0 }.max() ?? now
        guard pretendsAway || now.timeIntervalSince(lastInput) >= Self.awayAfter else { return }
        let alerts = Self.alertsDue(in: Array(ProjectStore.shared.projects.values), now: now, sent: Set(state.alerts.keys))
            .map { CloudBoard.alert(id: $0.id, title: $0.title, body: $0.body, project: $0.project) }
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

    // MARK: - Changes from the iPhone

    /// A hook is waiting for a permission prompt's answer, which may come from the iPhone: send the
    /// board now, and read the inbox every few seconds until nothing waits.
    func permissionAsked() {
        boardChanged(soon: true)
        if sendsAlerts, database != nil { Task { await sendAlerts() } }
        guard isOn, database != nil, quickInbox == nil else { return }
        quickInbox = Task { [weak self] in
            while !Task.isCancelled, PermissionDesk.shared.isWaiting {
                try? await Task.sleep(for: .seconds(3))
                await self?.readInbox()
            }
            self?.quickInbox = nil
        }
    }

    /// Folds in what was changed on the iPhone (to-dos, snoozes), then clears it from the inbox. One
    /// for a project this Mac doesn't have stays for another Mac, a day at most.
    private func readInbox() async {
        guard let database else { return }
        guard let changes = try? await CloudBoard.fetchChanges(from: database), !changes.isEmpty else { return }
        let done = changes.filter { Self.fold($0.change, into: ProjectStore.shared, digests: DigestStore.shared) }.map(\.id)
        guard !done.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: done, atomically: false)
        log.info("Folded in \(done.count) changes from the iPhone")
    }

    /// Folds one change from the iPhone into the board, and says whether it's done with, so the inbox
    /// can let it go. A to-do for a project no Mac has heard of yet waits a day for one to.
    static func fold(_ change: CloudBoard.Change, into store: ProjectStore, digests: DigestStore, now: Date = .now) -> Bool {
        switch change.kind {
        case .todo:
            guard let todo = change.todo, let project = change.project else { return true }
            let here = store.projectID(matching: project, name: change.projectName ?? project, repo: nil)
            return store.mergeTodo(todo, into: here) || now.timeIntervalSince(todo.updated) > 86_400
        case .snooze:
            if let nudge = change.nudge, let snooze = change.snooze { digests.applySnooze(snooze, to: nudge) }
            return true
        case .permission:
            guard let id = change.permission, let allow = change.allow else { return true }
            let known = store.local.values.contains { $0.sessions.contains { $0.permission?.id == id } }
            let answered = store.answerPermission(id, allow: allow, from: String(localized: "the iPhone"))
            // One this Mac never had is another Mac's to answer, for as long as its hook could wait.
            return answered || known || now.timeIntervalSince(change.answered ?? .distantPast) > ClaudeSetup.permissionWait
        }
    }

    // MARK: - For the digest

    /// When you last used any of your Macs, as far as this one knows.
    var lastUsedAnyMac: Date {
        if pretendsAway { return .distantPast }
        return [Date.now.addingTimeInterval(-Presence.secondsSinceInput), otherMacsInput].compactMap { $0 }.max() ?? .now
    }

    /// Whether this Mac can reach the iPhone with an alert.
    var reachesPhone: Bool { database != nil && isOn && sendsAlerts }

    /// An alert of the Mac's own making (the morning digest), named so two Macs sending it make one.
    func sendAlert(id: String, title: String, body: String, project: String) async -> Bool {
        guard let database else { return false }
        do {
            let (saved, _) = try await database.modifyRecords(saving: [CloudBoard.alert(id: id, title: title, body: body, project: project)],
                                                            deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            switch saved.values.first {
            case .success: break
            case .failure(let error) where (error as? CKError)?.code == .serverRecordChanged: break
            default: return false
            }
            state.alerts[id] = .now
            save()
            return true
        } catch {
            log.error("Couldn't send the digest to the iPhone: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Makes the iPhone's alerts subscription when it's missing. The iPhone app makes it too, but
    /// iCloud has refused the iPhone's save while taking the Mac's; either works, since a subscription
    /// belongs to the iCloud account, not the device that made it.
    private func subscribeToAlerts() async {
        guard let database, !hasAlertsSubscription else { return }
        guard let subscriptions = try? await database.allSubscriptions() else { return }
        // One from before alerts could be changed on the iPhone (to add Allow and Deny) is replaced.
        if let existing = subscriptions.first(where: { $0.subscriptionID == CloudBoard.alertSubscription }),
           existing.notificationInfo?.shouldSendMutableContent == true {
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

    struct Alert: Equatable {
        var id: String
        var title: String
        var body: String
        var project: String
    }

    /// The alerts due now, while you're away, that haven't gone (`sent`): a permission prompt, and a
    /// tester's crash or screenshot, at once; anything else that needs you once it has for two minutes.
    nonisolated static func alertsDue(in projects: [Project], now: Date, sent: Set<String>) -> [Alert] {
        var alerts: [Alert] = []
        for project in projects where !project.hidden {
            for session in project.liveSessions(at: now) where [.waiting, .yourCall, .blocked].contains(session.state) {
                if let ask = session.permission, ask.isOpen(at: now) {
                    let id = PermissionAlert.recordName(for: ask.id)
                    guard !sent.contains(id) else { continue }
                    let (title, body) = PermissionDesk.alert(for: ask, in: session, project: project)
                    alerts.append(Alert(id: id, title: title, body: body, project: project.id))
                    continue
                }
                guard now.timeIntervalSince(session.since) >= alertDelay else { continue }
                let id = "\(session.id).\(session.state.rawValue).\(Int(session.since.timeIntervalSince1970))"
                guard !sent.contains(id) else { continue }
                let (title, body) = text(for: session.state, project: project, session: session)
                alerts.append(Alert(id: id, title: title, body: body, project: project.id))
            }
            for item in project.appStore?.feedback ?? [] {
                guard let learned = item.seen, now.timeIntervalSince(learned) < feedbackAlertWindow else { continue }
                let id = "feedback.\(item.id)"
                guard !sent.contains(id) else { continue }
                let (title, body) = item.alert(in: project.name)
                alerts.append(Alert(id: id, title: title, body: body, project: project.id))
            }
            if project.reported == .blocked, now.timeIntervalSince(project.reportedAt) >= alertDelay,
               now.timeIntervalSince(project.reportedAt) < 86_400 {
                let id = "\(project.id).blocked.\(Int(project.reportedAt.timeIntervalSince1970))"
                if !sent.contains(id) {
                    let (title, body) = text(for: .blocked, project: project, session: nil)
                    alerts.append(Alert(id: id, title: title, body: body, project: project.id))
                }
            }
        }
        return alerts
    }

    nonisolated private static func text(for state: ProjectState, project: Project, session: Session?) -> (String, String) {
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
    func debugCheck(testAlert: Bool = false, forget: String? = nil, change: String? = nil) async -> [String: String] {
        guard let database else { return ["error": "not entitled"] }
        var result: [String: String] = ["status": "\(status)"]
        do {
            let board = try await CloudBoard.fetchBoard(from: database)
            result["projects"] = "\(board.projects.count)"
            result["digest"] = board.digest.map { "\($0.title) | \($0.waiting.count) waiting, \($0.todos.count) old to-do groups" } ?? "none"
            result["passport"] = board.passport.map { passport in
                PassportPeriod.allCases.map { "\($0.rawValue): \(Formats.hours(passport[$0]?.total.seconds ?? 0)) h" }.joined(separator: ", ")
                    + " | " + passport.macs.joined(separator: ", ")
            } ?? "none"
        } catch {
            result["read"] = "\(error)"
        }
        result["inbox"] = (try? await CloudBoard.fetchChanges(from: database)).map { "\($0.count) waiting" } ?? "no inbox"
        // ?change=<project id>: a to-do and a snooze, as the iPhone would send them.
        if let change, let project = ProjectStore.shared[change] {
            do {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: CloudBoard.inboxZoneID)], deleting: [])
                let now = Date.now
                let todo = CloudBoard.Change(kind: .todo, project: project.id, projectName: project.name,
                                             todo: Todo(text: "Added on the iPhone", created: now, updated: now))
                let snooze = CloudBoard.Change(kind: .snooze, nudge: "loose|\(project.id)",
                                               snooze: DigestState.Snooze(until: now.addingTimeInterval(86_400), set: now))
                _ = try await database.modifyRecords(saving: [try CloudBoard.record(for: todo), try CloudBoard.record(for: snooze)], deleting: [])
                result["change"] = "sent a to-do and a snooze for \(project.id)"
            } catch {
                result["change"] = "\(error)"
            }
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
