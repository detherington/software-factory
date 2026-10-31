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

    /// A reply's alert: a turn that ended asking you something, while a Mac's hook waits for a reply.
    /// Its name says how many options its body's last line lists, which the extension makes buttons of.
    static func replyRecordName(for session: String, since: Date, options: Int) -> String {
        replyPrefix + "\(session).\(Int(since.timeIntervalSince1970)).\(options)"
    }
    private static let replyPrefix = "reply."
    /// Where the extension leaves the session a reply alert is for, and its options.
    static let replyKey = "reply"
    static let optionsKey = "options"
    /// Between the options, on the body's last line.
    static let optionSeparator = " · "

    /// The session a reply alert's record is for, and how many options it lists.
    static func reply(fromRecordName name: String) -> (session: String, options: Int)? {
        guard name.hasPrefix(replyPrefix) else { return nil }
        let parts = name.dropFirst(replyPrefix.count).split(separator: ".")
        guard parts.count >= 3, let options = Int(parts[parts.count - 1]) else { return nil }
        return (parts.dropLast(2).joined(separator: "."), options)
    }

    /// A reply alert's session and how many options it lists, from its push.
    static func reply(in userInfo: [AnyHashable: Any]) -> (session: String, options: Int)? {
        let name = (CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification)?.recordID?.recordName
        return name.flatMap(reply(fromRecordName:))
    }

    /// The session a reply alert is about, from what the extension left in it or its push.
    static func replySession(in userInfo: [AnyHashable: Any]) -> String? {
        userInfo[replyKey] as? String ?? reply(in: userInfo)?.session
    }

    /// The options a reply alert's body lists on its last line, when there are `count` of them.
    static func options(inBody body: String, count: Int) -> [String] {
        guard count > 0, let last = body.split(separator: "\n").last, body.contains("\n") else { return [] }
        let options = last.components(separatedBy: optionSeparator)
        return options.count == count ? options : []
    }

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
