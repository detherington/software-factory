import CloudKit
import Foundation

/// The board as the iPhone sees it, in your private iCloud database: each project is a record in the
/// Board zone, written by the Macs and read by the iPhone app and its widgets, and so are today's
/// digest and the Passport. Alerts are records in the default zone, which a subscription on the iPhone turns into
/// notifications. What you change on the iPhone (a to-do, a snooze) goes to the Inbox zone, where
/// the Macs pick it up, fold it into the board and delete it.
///
/// The container is in each app's Info.plist (`FactoryCloudKitContainer`). Debug builds use its
/// development environment and Release builds production, so testing never reaches the real board.
nonisolated enum CloudBoard {
    static let zoneID = CKRecordZone.ID(zoneName: "Board", ownerName: CKCurrentUserDefaultName)
    static let inboxZoneID = CKRecordZone.ID(zoneName: "Inbox", ownerName: CKCurrentUserDefaultName)

    enum Field {
        static let data = "data"
        static let name = "name"
        static let updated = "updated"
        static let machine = "machine"
        static let title = "title"
        static let body = "body"
        static let project = "project"
        static let created = "created"
    }

    static let projectType = "Project"
    static let alertType = "Alert"
    static let digestType = "Digest"
    static let changeType = "Change"
    /// The digest's one record, replaced as it changes.
    static let digestRecordName = "today"
    /// The Passport's one record. It's a Project record, so the schema needs no new type: without a
    /// project's id and name, iPhone builds from before it pass over it. No project id has a dot.
    static let passportRecordName = "factory.passport"
    /// The subscriptions the iPhone makes: board changes (silent), and alerts (shown).
    static let boardSubscription = "board-changes"
    static let alertSubscription = "alerts"

    static var container: CKContainer? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "FactoryCloudKitContainer") as? String, !id.isEmpty else { return nil }
        return CKContainer(identifier: id)
    }

    // MARK: - Projects

    /// What the iPhone needs of a project: no folder paths or transcripts, and its latest events.
    static func phoneCopy(_ project: Project) -> Project {
        var copy = project
        copy.path = nil
        copy.events = Array(project.events.prefix(25))
        copy.todos = project.todos?.filter { !$0.deleted }
        copy.sessions = project.sessions.sorted { $0.updated > $1.updated }.prefix(6).map { session in
            var session = session
            session.transcript = nil
            return session
        }
        // A worktree with nothing left in it matters only for the branch of a session there.
        copy.looseEnds = project.looseEnds?.filter { ends in
            !ends.isEmpty || ends.worktree == nil || copy.sessions.contains { $0.machine == ends.machine && $0.worktree == ends.worktree }
        }
        return copy
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONDates.encoding
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONDates.decoding
        return try? decoder.decode(type, from: data)
    }

    static func recordID(for projectID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: projectID, zoneID: zoneID)
    }

    static func record(_ data: Data, for project: Project, machine: String) -> CKRecord {
        let record = CKRecord(recordType: projectType, recordID: recordID(for: project.id))
        record[Field.data] = data
        record[Field.name] = project.name
        record[Field.updated] = Date.now
        record[Field.machine] = machine
        return record
    }

    typealias Board = (projects: [Project], digest: Digest?, passport: Passport?)

    /// Every project in the zone, today's digest and the Passport. There are a few dozen records, so
    /// it reads them all each time.
    static func fetchBoard(from database: CKDatabase) async throws -> Board {
        board(from: try await allRecords(in: zoneID, from: database))
    }

    static func board(from records: [CKRecord]) -> Board {
        var projects: [Project] = []
        var digest: Digest?
        var passport: Passport?
        for record in records {
            guard let data = record[Field.data] as? Data else { continue }
            if record.recordID.recordName == passportRecordName {
                passport = decode(Passport.self, from: data)
            } else if record.recordType == digestType {
                digest = decode(Digest.self, from: data)
            } else if let project = decode(Project.self, from: data) {
                projects.append(project)
            }
        }
        return (projects, digest, passport)
    }

    static func fetchProjects(from database: CKDatabase) async throws -> [Project] {
        try await fetchBoard(from: database).projects
    }

    static func allRecords(in zone: CKRecordZone.ID, from database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zone, since: token)
            for case .success(let modification) in changes.modificationResultsByID.values { records.append(modification.record) }
            token = changes.changeToken
            more = changes.moreComing
        }
        return records
    }

    // MARK: - The digest

    static func digestRecord(_ data: Data) -> CKRecord {
        let record = CKRecord(recordType: digestType, recordID: CKRecord.ID(recordName: digestRecordName, zoneID: zoneID))
        record[Field.data] = data
        record[Field.updated] = Date.now
        return record
    }

    // MARK: - The Passport

    /// The Passport's three periods, as a Mac adds them up: every Mac's numbers, with Sync on.
    struct Passport: Codable, Sendable {
        /// By period (`PassportPeriod.rawValue`).
        var periods: [String: PassportSummary]
        /// The Macs whose numbers it adds up, the one that sent it first.
        var macs: [String]
        /// When that Mac last read its transcripts.
        var read: Date?

        subscript(period: PassportPeriod) -> PassportSummary? { periods[period.rawValue] }
    }

    static func passportRecord(_ data: Data) -> CKRecord {
        let record = CKRecord(recordType: projectType, recordID: CKRecord.ID(recordName: passportRecordName, zoneID: zoneID))
        record[Field.data] = data
        record[Field.updated] = Date.now
        return record
    }

    // MARK: - Changes from the iPhone

    /// Something changed on the iPhone, for the Macs to fold in.
    struct Change: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case todo, snooze, permission, reply }

        var kind: Kind
        /// The project, as the board the iPhone saw names it, and its name, to find it on any Mac.
        var project: String?
        var projectName: String?
        /// The to-do as it now stands: added, ticked, reworded or deleted.
        var todo: Todo?
        /// A nudge snoozed, and until when.
        var nudge: String?
        var snooze: DigestState.Snooze?
        /// A permission prompt answered: its id, whether to allow it, and when; or a question
        /// answered, with its answers by the question's text.
        var permission: String?
        var allow: Bool?
        var answered: Date?
        var answers: [String: String]?
        /// A reply to a session whose turn ended: the session, and what you said (sent `answered`).
        var session: String?
        var text: String?
    }

    static func record(for change: Change) throws -> CKRecord {
        let record = CKRecord(recordType: changeType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: inboxZoneID))
        record[Field.data] = try encode(change)
        record[Field.created] = Date.now
        return record
    }

    /// What's waiting in the inbox, oldest first.
    static func fetchChanges(from database: CKDatabase) async throws -> [(id: CKRecord.ID, change: Change)] {
        try await allRecords(in: inboxZoneID, from: database)
            .sorted { ($0[Field.created] as? Date ?? .distantPast) < ($1[Field.created] as? Date ?? .distantPast) }
            .compactMap { record in
                (record[Field.data] as? Data).flatMap { decode(Change.self, from: $0) }.map { (record.recordID, $0) }
            }
    }

    // MARK: - Subscriptions

    /// The board changed: a silent push, so the iPhone app fetches it.
    static func boardChangesSubscription() -> CKDatabaseSubscription {
        let subscription = CKDatabaseSubscription(subscriptionID: boardSubscription)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    /// An alert was saved: a notification with its words, which the Mac wrote. The keys
    /// (Localizable.strings) only show them.
    static func alertsSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: alertType, predicate: NSPredicate(value: true),
                                               subscriptionID: alertSubscription, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "ALERT_TITLE"
        info.titleLocalizationArgs = [Field.title]
        info.alertLocalizationKey = "ALERT_BODY"
        info.alertLocalizationArgs = [Field.body]
        info.soundName = "default"
        info.desiredKeys = [Field.project]
        // So the iPhone's notification extension can give a permission prompt's alert Allow and Deny.
        info.shouldSendMutableContent = true
        subscription.notificationInfo = info
        return subscription
    }

    // MARK: - Alerts

    static func alert(id: String, title: String, body: String, project: String) -> CKRecord {
        let record = CKRecord(recordType: alertType, recordID: CKRecord.ID(recordName: id))
        record[Field.title] = title
        record[Field.body] = body
        record[Field.project] = project
        record[Field.created] = Date.now
        return record
    }
}
