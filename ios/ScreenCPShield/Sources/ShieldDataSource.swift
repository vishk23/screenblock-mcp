import ManagedSettings
import ManagedSettingsUI
import UIKit

/// iOS invokes this every time it renders a shield over a blocked app.
/// We log the hit (coaching signal) and render mode-aware buttons:
/// quota with rations left → "Unlock N min" (direct, handled by the action ext);
/// quota exhausted → no unlock button; strict → chat-only message; open → unlock.
final class ShieldDataSource: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        let gid = groupId(containing: application.token)
        logHit(groupId: gid)
        return branded(groupId: gid, singleApp: true)
    }

    override func configuration(
        shielding application: Application, in category: ActivityCategory
    ) -> ShieldConfiguration {
        let gid = groupId(containingCategory: category.token)
        logHit(groupId: gid)
        return branded(groupId: gid)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        logHit(groupId: nil)
        return branded(groupId: nil)
    }

    private func branded(groupId: String?, singleApp: Bool = false) -> ShieldConfiguration {
        // Self-healing render: the action extension records grants but its
        // enforcement writes don't reliably apply; this extension provably
        // runs on every shield render, so it applies them instead.
        let grants = AppGroupStore.grants + AppGroupStore.pendingLocalGrants
        if let gid = groupId, EnforcementEngine.activeGrant(for: gid, in: grants) != nil {
            AppGroupStore.appendEvent(DeviceEvent(type: "shield_self_heal", groupId: gid))
            EnforcementEngine.applyAllImmediateShields(policies: AppGroupStore.policies, grants: grants)
        }
        let group = AppGroupStore.groups.first { $0.id == groupId }
        let used = groupId.map {
            EnforcementEngine.quotaUsedToday(
                groupId: $0, grants: AppGroupStore.grants + AppGroupStore.pendingLocalGrants)
        } ?? 0

        var subtitle = "Ask ChatGPT if you need time here."
        var unlockLabel: String?
        switch group?.mode {
        case "quota":
            let left = max(0, (group?.quotaPerDay ?? 0) - used)
            if left > 0 {
                unlockLabel = singleApp
                    ? "Unlock this app \(group?.quotaMinutes ?? 10) min (\(left) left)"
                    : "Unlock \(group?.quotaMinutes ?? 10) min (\(left) left today)"
                subtitle = "One tap spends a ration — your coach sees it."
            } else {
                subtitle = "All \(group?.quotaPerDay ?? 0) unlocks used today. Ask ChatGPT."
            }
        case "open":
            unlockLabel = "Unlock \(group?.quotaMinutes ?? 10) min"
        case "strict":
            subtitle = "Strict mode — your ChatGPT coach is the only door."
        default:
            break
        }

        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            icon: UIImage(systemName: "hourglass"),
            title: .init(text: "Blocked by ScreenCP", color: .white),
            subtitle: .init(text: subtitle, color: .lightGray),
            primaryButtonLabel: .init(text: "OK", color: .black),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: unlockLabel.map { .init(text: $0, color: .white) }
        )
    }

    /// Most-specific group containing this app token (per-app groups win).
    private func groupId(containing token: ApplicationToken?) -> String? {
        token.flatMap { EnforcementEngine.groupContaining(appToken: $0) }
    }

    private func groupId(containingCategory token: ActivityCategoryToken?) -> String? {
        guard let token else { return nil }
        for group in AppGroupStore.groups {
            if AppGroupStore.selection(for: group.id)?.categoryTokens.contains(token) == true {
                return group.id
            }
        }
        return nil
    }

    /// Log at most one hit per group per 30s — iOS may render the shield several
    /// times per encounter, and each open-attempt is one coaching datapoint.
    private func logHit(groupId: String?) {
        let key = "lastShieldHit_\(groupId ?? "unknown")"
        let now = Date().timeIntervalSince1970
        if now - AppGroupStore.suite.double(forKey: key) < 30 { return }
        AppGroupStore.suite.set(now, forKey: key)
        AppGroupStore.appendEvent(DeviceEvent(type: "shield_shown", groupId: groupId))
    }
}
