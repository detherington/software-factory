import UserNotifications

/// Gives a permission prompt's alert Allow and Deny, and a reply's alert its options and Reply. The
/// Mac names the alert's record for what it's about ("permission.<id>", "reply.<session>.…"); this
/// sees that in the push, before iOS shows it, and gives it the category whose buttons the app
/// answers. Every other alert passes through as it came.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        if let ask = PermissionAlert.ask(in: request.content.userInfo) {
            content.categoryIdentifier = PermissionAlert.category
            content.userInfo[PermissionAlert.key] = ask
            contentHandler(content)
            return
        }
        guard let reply = PermissionAlert.reply(in: request.content.userInfo) else {
            contentHandler(request.content)
            return
        }
        // The options are the body's last line, which the alert shows as well.
        let options = PermissionAlert.options(inBody: content.body, count: reply.options)
        content.userInfo[PermissionAlert.replyKey] = reply.session
        content.userInfo[PermissionAlert.optionsKey] = options
        var actions = options.prefix(4).enumerated().map { index, label in
            UNNotificationAction(identifier: "option.\(index)", title: label, options: [])
        }
        actions.append(UNTextInputNotificationAction(identifier: "reply", title: String(localized: "Reply…"), options: [],
                                                     textInputButtonTitle: String(localized: "Send"),
                                                     textInputPlaceholder: String(localized: "Your reply")))
        // A category of its own; the app clears those for turns that have moved on.
        let identifier = "reply.\(reply.session)"
        content.categoryIdentifier = identifier
        // UserNotifications hands these over unannotated; from here on, only the task uses them.
        nonisolated(unsafe) let category = UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [])
        nonisolated(unsafe) let deliver = { contentHandler(content) }
        Task {
            let center = UNUserNotificationCenter.current()
            var categories = await center.notificationCategories().filter { $0.identifier != identifier }
            categories.insert(category)
            center.setNotificationCategories(categories)
            // Registering takes a moment to reach the system, which reads the category as the alert shows.
            try? await Task.sleep(for: .milliseconds(500))
            deliver()
        }
    }
}
