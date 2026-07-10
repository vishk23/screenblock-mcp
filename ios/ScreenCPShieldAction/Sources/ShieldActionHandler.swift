import ManagedSettings
import UserNotifications
import Foundation
import os

/// Handles taps on the shield's buttons. The shield cannot open apps (iOS rule),
/// so "Request time" posts a Time-Sensitive local notification whose tap opens
/// ScreenCP straight into the unlock sheet (pendingUnlockGroupId routing).
final class ShieldActionHandler: ShieldActionDelegate {

    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(action, groupId: groupId { $0.applicationTokens.contains(application) }, completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for webDomain: WebDomainToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(action, groupId: groupId { $0.webDomainTokens.contains(webDomain) }, completionHandler)
    }

    override func handle(
        action: ShieldAction,
        for category: ActivityCategoryToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        respond(action, groupId: groupId { $0.categoryTokens.contains(category) }, completionHandler)
    }

    private func respond(
        _ action: ShieldAction,
        groupId: String?,
        _ completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        switch action {
        case .secondaryButtonPressed:
            AppGroupStore.suite.set(groupId ?? "", forKey: "pendingUnlockGroupId")

            // Local notifications from this extension are silently dropped on
            // some iOS versions — ask the server to send a real push instead
            // (plain visible, no mutable-content, so the NSE leaves it alone).
            let groupName = AppGroupStore.groups.first { $0.id == groupId }?.name
            var req = URLRequest(url: URL(string: "\(Secrets.baseURL)/device/nudge")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "body": "Tap to request time\(groupName.map { " for \($0)" } ?? "")",
            ])
            let finished = OSAllocatedUnfairLock(initialState: false)
            let finishOnce: () -> Void = {
                let first = finished.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { completionHandler(.close) }
            }
            let task = URLSession.shared.dataTask(with: req) { _, _, _ in finishOnce() }
            task.resume()
            // Belt + suspenders: also attempt the local notification, and never
            // hang past 3s if the network stalls.
            let content = UNMutableNotificationContent()
            content.title = "ScreenCP"
            content.body = "Tap to request time"
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                task.cancel()
                finishOnce()
            }
        default:
            completionHandler(.close)
        }
    }

    private func groupId(_ contains: (FamilyActivitySelectionProbe) -> Bool) -> String? {
        for group in AppGroupStore.groups {
            if let sel = AppGroupStore.selection(for: group.id),
               contains(.init(applicationTokens: sel.applicationTokens,
                              categoryTokens: sel.categoryTokens,
                              webDomainTokens: sel.webDomainTokens)) {
                return group.id
            }
        }
        return nil
    }
}

/// Plain value bag so the closure-based lookup stays readable.
struct FamilyActivitySelectionProbe {
    let applicationTokens: Set<ApplicationToken>
    let categoryTokens: Set<ActivityCategoryToken>
    let webDomainTokens: Set<WebDomainToken>
}
