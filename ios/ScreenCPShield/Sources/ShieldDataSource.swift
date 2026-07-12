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
        let hits = AppGroupStore.shieldHitsToday(groupId: groupId)

        // Title carries the group name; streak-aware so the shield never goes stale.
        let name = group?.name ?? "This app"
        let title = Self.streakTitle(name: name, hits: hits)

        var subtitle = "Ask your coach in \(Brand.name) if you need time here."
        var unlockLabel: String?
        switch group?.mode {
        case "quota":
            let left = max(0, (group?.quotaPerDay ?? 0) - used)
            if left > 0 {
                unlockLabel = singleApp
                    ? "Unlock this app · \(group?.quotaMinutes ?? 10) min"
                    : "Unlock \(group?.quotaMinutes ?? 10) min"
                subtitle = "\(left) of \(group?.quotaPerDay ?? 0) unlocks left today — one tap spends one."
            } else {
                subtitle = "You've used all \(group?.quotaPerDay ?? 0) unlocks today. Ask your coach."
            }
        case "open":
            unlockLabel = "Unlock \(group?.quotaMinutes ?? 10) min"
            subtitle = "Open mode — a tap gives you \(group?.quotaMinutes ?? 10) minutes."
        case "strict":
            subtitle = "Strict mode — your coach in \(Brand.name) holds the only key."
        default:
            break
        }

        return ShieldConfiguration(
            backgroundBlurStyle: .systemThinMaterialDark,
            backgroundColor: Self.tint(for: name),
            icon: UIImage(systemName: hits >= 4 ? "exclamationmark.circle" : "hourglass"),
            title: .init(text: title, color: .white),
            subtitle: .init(text: subtitle, color: UIColor.white.withAlphaComponent(0.75)),
            primaryButtonLabel: .init(text: "Not now", color: Self.tint(for: name)),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: unlockLabel.map { .init(text: $0, color: .white) }
        )
    }

    /// Escalating copy: gentle first, more pointed as the day's attempts pile up.
    static func streakTitle(name: String, hits: Int) -> String {
        switch hits {
        case 0, 1: return "\(name) is blocked"
        case 2, 3: return "\(name) again?"
        case 4, 5: return "\(name) — that's \(hits) times today"
        default:   return "\(name) · \(hits)× today. Everything okay?"
        }
    }

    /// Stable per-group color from the name, so each group reads as its own place.
    static func tint(for name: String) -> UIColor {
        let palette: [UIColor] = [
            UIColor(red: 0.36, green: 0.20, blue: 0.66, alpha: 1), // indigo
            UIColor(red: 0.13, green: 0.32, blue: 0.55, alpha: 1), // blue
            UIColor(red: 0.55, green: 0.20, blue: 0.42, alpha: 1), // magenta
            UIColor(red: 0.16, green: 0.40, blue: 0.38, alpha: 1), // teal
            UIColor(red: 0.52, green: 0.30, blue: 0.16, alpha: 1), // amber-brown
        ]
        let h = abs(name.lowercased().hashValue)
        return palette[h % palette.count]
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
        _ = AppGroupStore.bumpShieldHitToday(groupId: groupId)
        AppGroupStore.appendEvent(DeviceEvent(type: "shield_shown", groupId: groupId))
    }
}
