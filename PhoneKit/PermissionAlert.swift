import CloudKit
import Foundation

/// A permission prompt's alert on the iPhone. The Mac names the alert's record for the prompt, so
/// the iPhone's notification extension can give it Allow and Deny, and the app knows which prompt
/// they answer.
nonisolated enum PermissionAlert {
    /// The notification category with Allow and Deny, and its actions.
    static let category = "permission"
    static let allow = "allow"
    static let deny = "deny"
    /// Where the extension leaves the prompt's id in the notification.
    static let key = "permission"
    private static let prefix = "permission."

    static func recordName(for ask: String) -> String { prefix + ask }

    /// A question's alert, which has no Allow or Deny: tapping it opens the project, to choose there.
    static func questionRecordName(for ask: String) -> String { questionPrefix + ask }
    private static let questionPrefix = "question."

    /// The prompt or question an alert is about, to clear it once it's settled; nil for any other.
    static func prompt(in userInfo: [AnyHashable: Any]) -> String? {
        if let ask = ask(in: userInfo) { return ask }
        let name = (CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification)?.recordID?.recordName
        return name.flatMap { $0.hasPrefix(questionPrefix) ? String($0.dropFirst(questionPrefix.count)) : nil }
    }

    /// The prompt an alert's record is for; nil for any other alert.
    static func ask(fromRecordName name: String) -> String? {
        name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
    }

    /// The prompt an alert is about, from its push or what the extension left in it; nil for any other.
    static func ask(in userInfo: [AnyHashable: Any]) -> String? {
        if let ask = userInfo[key] as? String { return ask }
        let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification
        return notification?.recordID.flatMap { ask(fromRecordName: $0.recordName) }
    }
}
