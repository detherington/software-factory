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

final class PhoneDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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

    /// Tapping an alert opens its project.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let notification = CKNotification(fromRemoteNotificationDictionary: info) as? CKQueryNotification,
              let project = notification.recordFields?[CloudBoard.Field.project] as? String else { return }
        await MainActor.run { PhoneBoard.shared.opened = project }
    }
}
