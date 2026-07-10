import ManagedSettings
import Foundation

/// Handles taps on the shield's buttons. The secondary button is a DIRECT
/// unlock: this extension holds the same enforcement powers as the app, so
/// for quota/open groups it lifts the shield on the spot (one ration spent,
/// logged for coaching) and lets the blocked app open. Strict groups never
/// show the button. No notifications, no app-hopping.
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
            AppGroupStore.appendEvent(DeviceEvent(type: "shield_action_tapped", groupId: groupId))
            if let groupId {
                _ = EnforcementEngine.unlockFromShield(groupId: groupId)
            }
            // Close; the next shield render self-heals (lifts shields for the
            // recorded grant) so reopening the app walks straight through.
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
