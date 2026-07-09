import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Translates synced policy into OS enforcement primitives.
/// Precedence (spec §8): grant > block_now > schedule/limit.
/// One named ManagedSettingsStore per group so groups don't clobber each other.
enum EnforcementEngine {

    static func storeName(_ groupId: String) -> ManagedSettingsStore.Name {
        .init("group_\(groupId)")
    }

    static func activeGrant(for groupId: String, in grants: [RemoteGrant], now: Date = Date()) -> RemoteGrant? {
        grants.first { g in
            g.groupId == groupId
                && (g.status == "pending" || g.status == "active")
                && (ISO.date(g.expiresAt).map { $0 > now } ?? false)
        }
    }

    /// Apply the current shield state for one group (block policies + grants).
    /// Schedules/limits are OS-scheduled separately in `reconcileSchedules`.
    static func applyImmediateShield(groupId: String, policies: [RemotePolicy], grants: [RemoteGrant], now: Date = Date()) {
        let store = ManagedSettingsStore(named: storeName(groupId))
        guard let selection = AppGroupStore.selection(for: groupId) else { return }

        if activeGrant(for: groupId, in: grants, now: now) != nil {
            clearShield(store)
            return
        }

        let blocked = policies.contains { p in
            p.groupId == groupId && p.active && p.kind == "block"
                && (p.until == nil || (ISO.date(p.until!).map { $0 > now } ?? true))
        }

        if blocked {
            shield(store, selection: selection)
        } else if !scheduleWindowActive(groupId: groupId, policies: policies, now: now) {
            // Only clear if no schedule window is currently holding a shield —
            // the monitor extension owns shields inside schedule windows.
            clearShield(store)
        }
    }

    static func shield(_ store: ManagedSettingsStore, selection: FamilyActivitySelection) {
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil : .specific(selection.categoryTokens)
        // Websites picked in the FamilyActivityPicker get shielded in Safari too.
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
    }

    static func clearShield(_ store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
    }

    /// True if `now` falls inside any active schedule policy window for the group (device-local time).
    static func scheduleWindowActive(groupId: String, policies: [RemotePolicy], now: Date = Date()) -> Bool {
        let cal = Calendar.current
        let weekday0 = cal.component(.weekday, from: now) - 1 // Calendar: 1=Sun → server: 0=Sun
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        return policies.contains { p in
            guard p.groupId == groupId, p.active, p.kind == "schedule",
                  let days = p.daysOfWeek, days.contains(weekday0),
                  let s = hhmm(p.startTime), let e = hhmm(p.endTime) else { return false }
            return minutes >= s && minutes < e
        }
    }

    static func hhmm(_ s: String?) -> Int? {
        guard let s, s.count == 5 else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    // MARK: - OS-scheduled activities (schedules, limits, grant expiry)

    /// Re-registers all DeviceActivity monitoring from the current synced snapshot.
    /// Called by the main app after every sync. Idempotent: stops everything ours, re-registers.
    static func reconcileSchedules(groups: [RemoteGroup], policies: [RemotePolicy], grants: [RemoteGrant]) {
        let center = DeviceActivityCenter()
        center.stopMonitoring() // stops all activities owned by this app

        for group in groups {
            guard let selection = AppGroupStore.selection(for: group.id), hasContent(selection) else { continue }
            let groupPolicies = policies.filter { $0.groupId == group.id && $0.active }

            // Recurring block windows — one activity per weekday.
            for p in groupPolicies where p.kind == "schedule" {
                guard let s = clock(p.startTime), let e = clock(p.endTime), let days = p.daysOfWeek else { continue }
                for day in days {
                    let schedule = DeviceActivitySchedule(
                        intervalStart: DateComponents(hour: s.h, minute: s.m, weekday: day + 1),
                        intervalEnd: DateComponents(hour: e.h, minute: e.m, weekday: day + 1),
                        repeats: true
                    )
                    try? center.startMonitoring(.init("schedule_\(group.id)_\(day)"), during: schedule)
                }
            }

            // Daily limit — threshold events at 50/80/100%.
            for p in groupPolicies where p.kind == "limit" {
                guard let total = p.minutesPerDay else { continue }
                let schedule = DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: 0, minute: 0),
                    intervalEnd: DateComponents(hour: 23, minute: 59),
                    repeats: true
                )
                var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
                for pct in [50, 80, 100] {
                    let mins = max(1, total * pct / 100)
                    events[.init("limit_\(group.id)_\(pct)_\(mins)")] = DeviceActivityEvent(
                        applications: selection.applicationTokens,
                        categories: selection.categoryTokens,
                        webDomains: [],
                        threshold: DateComponents(minute: mins)
                    )
                }
                try? center.startMonitoring(.init("limit_\(group.id)"), during: schedule, events: events)
            }

            // Grant expiry — one-shot window ending at expiresAt; intervalDidEnd re-blocks.
            if let grant = activeGrant(for: group.id, in: grants),
               let expires = ISO.date(grant.expiresAt), expires > Date() {
                let cal = Calendar.current
                let start = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
                let end = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: expires)
                let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
                try? center.startMonitoring(.init("grantend_\(group.id)"), during: schedule)
            }
        }
    }

    static func hasContent(_ s: FamilyActivitySelection) -> Bool {
        !s.applicationTokens.isEmpty || !s.categoryTokens.isEmpty
    }

    private static func clock(_ s: String?) -> (h: Int, m: Int)? {
        guard let total = hhmm(s) else { return nil }
        return (total / 60, total % 60)
    }

    /// Full local reconcile: immediate shields for every group + OS schedule registration.
    static func reconcileAll() {
        let groups = AppGroupStore.groups
        let policies = AppGroupStore.policies
        let grants = AppGroupStore.grants
        for group in groups {
            applyImmediateShield(groupId: group.id, policies: policies, grants: grants)
        }
        reconcileSchedules(groups: groups, policies: policies, grants: grants)
    }
}
