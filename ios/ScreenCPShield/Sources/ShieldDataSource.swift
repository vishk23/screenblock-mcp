import ManagedSettings
import ManagedSettingsUI
import UIKit

/// iOS invokes this every time it renders a shield over a blocked app.
/// We log the hit (coaching signal for get_today_summary) and brand the shield.
final class ShieldDataSource: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        logHit(groupId: groupId(containing: application.token))
        return branded()
    }

    override func configuration(
        shielding application: Application, in category: ActivityCategory
    ) -> ShieldConfiguration {
        logHit(groupId: groupId(containingCategory: category.token))
        return branded()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        logHit(groupId: nil)
        return branded()
    }

    private func branded() -> ShieldConfiguration {
        // After a "Request time" tap, the next render guides the user onward
        // (the shield itself cannot open apps or post notifications reliably).
        let pending = !(AppGroupStore.suite.string(forKey: "pendingUnlockGroupId") ?? "").isEmpty
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            icon: UIImage(systemName: pending ? "arrow.up.forward.app" : "hourglass"),
            title: .init(text: "Blocked by ScreenCP", color: .white),
            subtitle: .init(
                text: pending
                    ? "Request started — open ScreenCP to choose your reason and unlock."
                    : "Ask ChatGPT if you need time here.",
                color: .lightGray),
            primaryButtonLabel: .init(text: "OK", color: .black),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: .init(text: pending ? "Request pending…" : "Request time", color: .white)
        )
    }

    /// Which group's selection contains this app token?
    private func groupId(containing token: ApplicationToken?) -> String? {
        guard let token else { return nil }
        for group in AppGroupStore.groups {
            if AppGroupStore.selection(for: group.id)?.applicationTokens.contains(token) == true {
                return group.id
            }
        }
        return nil
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
