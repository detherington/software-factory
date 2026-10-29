import CloudKit
import Foundation

/// The board as the iPhone sees it, in your private iCloud database: each project is a record in the
/// Board zone, written by the Macs and read by the iPhone app and its widgets. Alerts are records in
/// the default zone, which a subscription on the iPhone turns into notifications.
///
/// The container is in each app's Info.plist (`FactoryCloudKitContainer`). Debug builds use its
/// development environment and Release builds production, so testing never reaches the real board.
nonisolated enum CloudBoard {
    static let zoneID = CKRecordZone.ID(zoneName: "Board", ownerName: CKCurrentUserDefaultName)

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
        return copy
    }

    static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONDates.encoding
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(project)
    }

    static func decode(_ data: Data) -> Project? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONDates.decoding
        return try? decoder.decode(Project.self, from: data)
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

    /// Every project in the zone. There are a few dozen, so it reads them all each time.
    static func fetchProjects(from database: CKDatabase) async throws -> [Project] {
        var projects: [Project] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for case .success(let modification) in changes.modificationResultsByID.values {
                if let data = modification.record[Field.data] as? Data, let project = decode(data) { projects.append(project) }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return projects
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
