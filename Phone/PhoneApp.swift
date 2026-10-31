import CloudKit
import SwiftUI
import UIKit
import UserNotifications

/// Software Factory on the iPhone: the board your Macs keep, with widgets, and an alert when
/// something needs you while you're away from them. It only reads; the Macs do the work.
@main
struct PhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environment(PhoneBoard.shared)
                .tint(Switchyard.accent)
                .preferredColorScheme(.dark)
                .onOpenURL { PhoneBoard.shared.open($0) }
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await PhoneBoard.shared.refresh() } }
        }
    }
}

/// UIKit calls its notification delegate on the main thread, before Swift's concurrency checking knew
/// it (hence `@preconcurrency`).
final class PhoneDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // A permission prompt's alert (its notification extension gives it this category). Allowing
        // a command runs it on your Mac, so it asks for Face ID first; denying doesn't.
        let allow = UNNotificationAction(identifier: PermissionAlert.allow, title: String(localized: "Allow"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: PermissionAlert.deny, title: String(localized: "Deny"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: PermissionAlert.category, actions: [allow, deny], intentIdentifiers: [])])
        application.registerForRemoteNotifications()
        Task { await PhoneBoard.shared.setUp() }
        return true
    }

    /// iCloud saying the board changed.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await PhoneBoard.shared.refresh()
        return .newData
    }

    /// Alerts show even with the app open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Tapping an alert opens its project; Allow or Deny answers its permission prompt, and a reply's
    /// options or Reply answer a turn that ended, without opening the app. On the main actor: Swift hands UIKit's completion handler back from wherever this
    /// finishes, and UIKit aborts if that isn't the main thread (tapping an alert from the Home Screen did).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let notification = CKNotification(fromRemoteNotificationDictionary: info) as? CKQueryNotification
        let project = notification?.recordFields?[CloudBoard.Field.project] as? String
        let action = response.actionIdentifier
        if action == PermissionAlert.allow || action == PermissionAlert.deny, let ask = PermissionAlert.ask(in: info) {
            await PhoneBoard.shared.answer(ask: ask, allow: action == PermissionAlert.allow, project: project)
            return
        }
        // A reply's option, or your own words.
        if let session = PermissionAlert.replySession(in: info) {
            let options = info[PermissionAlert.optionsKey] as? [String] ?? []
            let index = action.hasPrefix("option.") ? Int(action.dropFirst("option.".count)) : nil
            let text = action == "reply" ? (response as? UNTextInputNotificationResponse)?.userText
                : index.flatMap { options.indices.contains($0) ? options[$0] : nil }
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                await PhoneBoard.shared.reply(session: session, text: text, project: project)
                return
            }
        }
        guard let project else { return }
        PhoneBoard.shared.opened = project
    }
}
