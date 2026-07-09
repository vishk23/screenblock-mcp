import DeviceActivity
import ManagedSettings
import Foundation

/// OS-invoked at schedule boundaries and usage thresholds.
/// Activity name conventions (set in EnforcementEngine.reconcileSchedules):
///   schedule_<groupId>_<day>   recurring block window
///   limit_<groupId>            daily threshold ladder
///   grantend_<groupId>         one-shot grant expiry
/// Event name convention: limit_<groupId>_<pct>_<minutes>
final class MonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        let parts = activity.rawValue.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return }
        let groupId = parts[1]

        if parts[0] == "schedule" {
            // Respect an active grant: don't shield mid-grant.
            if EnforcementEngine.activeGrant(for: groupId, in: AppGroupStore.grants) != nil { return }
            applyShield(groupId)
            AppGroupStore.appendEvent(DeviceEvent(type: "policy_applied", groupId: groupId))
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        let parts = activity.rawValue.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return }
        let groupId = parts[1]

        switch parts[0] {
        case "schedule":
            // Window over — clear unless a block policy still holds.
            EnforcementEngine.applyImmediateShield(
                groupId: groupId, policies: AppGroupStore.policies, grants: AppGroupStore.grants)
        case "grantend":
            // Grant expired — re-apply whatever policy demands right now.
            var grants = AppGroupStore.grants
            for i in grants.indices where grants[i].groupId == groupId {
                if ISO.date(grants[i].expiresAt).map({ $0 <= Date() }) ?? false,
                   grants[i].status == "pending" || grants[i].status == "active" {
                    grants[i] = RemoteGrant(
                        id: grants[i].id, groupId: grants[i].groupId, minutes: grants[i].minutes,
                        reason: grants[i].reason, startsAt: grants[i].startsAt,
                        expiresAt: grants[i].expiresAt, status: "expired",
                        source: grants[i].source, updatedAt: grants[i].updatedAt)
                }
            }
            AppGroupStore.grants = grants
            // Grant expiry changes punch-through exemptions for every group.
            EnforcementEngine.applyAllImmediateShields(policies: AppGroupStore.policies, grants: grants)
            AppGroupStore.appendEvent(DeviceEvent(type: "grant_expired", groupId: groupId))
        default:
            break
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        // limit_<groupId>_<pct>_<minutes>
        let parts = event.rawValue.split(separator: "_").map(String.init)
        guard parts.count == 4, parts[0] == "limit" else { return }
        let groupId = parts[1]
        let pct = Int(parts[2]) ?? 0
        let minutes = Int(parts[3]) ?? 0

        AppGroupStore.appendEvent(DeviceEvent(
            type: "threshold_crossed", groupId: groupId, meta: ["thresholdMinutes": minutes, "percent": pct]))

        if pct >= 100 {
            if EnforcementEngine.activeGrant(for: groupId, in: AppGroupStore.grants) != nil { return }
            applyShield(groupId)
            AppGroupStore.appendEvent(DeviceEvent(type: "shield_shown", groupId: groupId))
        }
    }

    private func applyShield(_ groupId: String) {
        guard let selection = AppGroupStore.selection(for: groupId) else { return }
        let store = ManagedSettingsStore(named: EnforcementEngine.storeName(groupId))
        EnforcementEngine.shield(
            store, selection: selection,
            exempt: EnforcementEngine.grantExemptTokens(grants: AppGroupStore.grants))
    }
}
