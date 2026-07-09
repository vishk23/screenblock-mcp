import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Alert permission is for the visible "Tap to apply" fallback (spec §7 rung 3).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let changed = AppGroupStore.apnsToken != hex
        AppGroupStore.apnsToken = hex
        if changed {
            Task { await SyncService.syncNow() } // re-register under the real token
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Stay on the local pseudo-token; foreground sync still works.
    }

    /// Silent push (content-available) — spec §7 rung 2: wake, sync, apply.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let error = await SyncService.syncNow()
            completionHandler(error == nil ? .newData : .failed)
        }
    }
}
