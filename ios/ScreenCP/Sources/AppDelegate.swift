import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Alert permission is for the visible "Tap to apply" fallback (spec §7 rung 3).
        // During first-run onboarding the ask is deferred to the flow's final step,
        // so the dialog doesn't stomp on the welcome screen.
        if AppGroupStore.suite.bool(forKey: "onboarded") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    /// Show nudges even while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Deep-link routing for tapped notifications (setup nudges carry a groupId).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let kind = userInfo["screencp"] as? String, kind == "setup",
           let groupId = userInfo["groupId"] as? String {
            AppGroupStore.suite.set(groupId, forKey: "pendingSetupGroupId")
        }
        completionHandler()
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
