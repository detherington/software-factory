import UserNotifications

/// Gives a permission prompt's alert Allow and Deny. The Mac names the alert's record for the prompt
/// ("permission.<id>"); this sees that in the push, before iOS shows it, and gives it the category
/// whose buttons the app answers. Every other alert passes through as it came.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let ask = PermissionAlert.ask(in: request.content.userInfo),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        content.categoryIdentifier = PermissionAlert.category
        content.userInfo[PermissionAlert.key] = ask
        contentHandler(content)
    }
}
