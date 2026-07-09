import ManagedSettings
import UserNotifications
import Foundation

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
            let content = UNMutableNotificationContent()
            content.title = "ScreenCP"
            content.body = "Tap to request time"
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            completionHandler(.close)
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
