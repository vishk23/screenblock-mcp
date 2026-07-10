import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Translates synced policy into OS enforcement primitives.
/// Precedence (spec §8): grant > block_now > schedule/limit.
/// One named ManagedSettingsStore per group so groups don't clobber each other.
enum EnforcementEngine {

    /// Grants with this reason are single-app: they must NOT lift the whole
    /// group's shield (their hole lives in AppGroupStore.tokenExemptions).
    static let singleAppReason = "Unlocked at the shield (this app only)"

    static func storeName(_ groupId: String) -> ManagedSettingsStore.Name {
        .init("group_\(groupId)")
    }

    static func activeGrant(for groupId: String, in grants: [RemoteGrant], now: Date = Date()) -> RemoteGrant? {
        grants.first { g in
            g.groupId == groupId
                && g.reason != singleAppReason // single-app holes never open the whole group
                && (g.status == "pending" || g.status == "active")
                && (ISO.date(g.expiresAt).map { $0 > now } ?? false)
        }
    }

    /// PUNCH-THROUGH: app tokens exempted by an active grant on ANY group.
    /// A grant on "Instagram" unblocks Instagram even while "Social" is blocked.
    /// Category tokens cannot be subtracted (opaque) — app-token picks only.
    static func grantExemptTokens(grants: [RemoteGrant], now: Date = Date()) -> Set<ApplicationToken> {
        var exempt = Set<ApplicationToken>()
        for group in AppGroupStore.groups where activeGrant(for: group.id, in: grants, now: now) != nil {
            if let sel = AppGroupStore.selection(for: group.id) {
                exempt.formUnion(sel.applicationTokens)
            }
        }
        // Single-app unlock holes.
        for (token, expiry) in AppGroupStore.tokenExemptions where expiry > now {
            exempt.insert(token)
        }
        return exempt
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

        if blocked || scheduleWindowActive(groupId: groupId, policies: policies, now: now) {
            // Re-asserting inside a schedule window keeps punch-through exemptions
            // current even when the monitor extension set the original shield.
            shield(store, selection: selection, exempt: grantExemptTokens(grants: grants, now: now))
        } else {
            clearShield(store)
        }
    }

    /// Re-apply every group's immediate shield (grant start/expiry changes exemptions everywhere).
    static func applyAllImmediateShields(policies: [RemotePolicy], grants: [RemoteGrant], now: Date = Date()) {
        for group in AppGroupStore.groups {
            applyImmediateShield(groupId: group.id, policies: policies, grants: grants, now: now)
        }
    }

    static func shield(_ store: ManagedSettingsStore, selection: FamilyActivitySelection, exempt: Set<ApplicationToken> = []) {
        let apps = selection.applicationTokens.subtracting(exempt)
        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil : .specific(selection.categoryTokens)
        // Websites picked in the FamilyActivityPicker get shielded in Safari too.
        store.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
        // Category picks also shield that category's WEBSITES (e.g. Social category
        // blocks instagram.com in Safari), including sites never visited before.
        store.shield.webDomainCategories = selection.categoryTokens.isEmpty
            ? nil : .specific(selection.categoryTokens)
    }

    static func clearShield(_ store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }

    /// True if `now` falls inside any active schedule policy window for the group (device-local time).
    /// Handles overnight windows (start > end, e.g. 22:00–02:00): the post-midnight
    /// portion belongs to the day AFTER the schedule's start day.
    static func scheduleWindowActive(groupId: String, policies: [RemotePolicy], now: Date = Date()) -> Bool {
        let cal = Calendar.current
        let today = cal.component(.weekday, from: now) - 1     // Calendar: 1=Sun → server: 0=Sun
        let yesterday = (today + 6) % 7
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        return policies.contains { p in
            guard p.groupId == groupId, p.active, p.kind == "schedule",
                  let days = p.daysOfWeek,
                  let s = hhmm(p.startTime), let e = hhmm(p.endTime) else { return false }
            if s < e {
                return days.contains(today) && minutes >= s && minutes < e
            }
            // Overnight (or s == e meaning all-day): active if we're past start on a
            // start day, or before end on the day following a start day.
            return (days.contains(today) && minutes >= s)
                || (days.contains(yesterday) && minutes < e)
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

            // Recurring block windows — one activity per weekday. Overnight windows
            // (start > end) are split into two well-formed same-day windows, since
            // DeviceActivitySchedule does not reliably span midnight in one interval.
            for p in groupPolicies where p.kind == "schedule" {
                guard let s = clock(p.startTime), let e = clock(p.endTime), let days = p.daysOfWeek else { continue }
                let startM = s.h * 60 + s.m, endM = e.h * 60 + e.m
                for day in days {
                    if startM < endM {
                        register(center, "schedule_\(group.id)_\(day)",
                                 startH: s.h, startMin: s.m, endH: e.h, endMin: e.m, weekday: day + 1)
                    } else {
                        // Pre-midnight portion on the start day…
                        register(center, "schedule_\(group.id)_\(day)_a",
                                 startH: s.h, startMin: s.m, endH: 23, endMin: 59, weekday: day + 1)
                        // …post-midnight portion on the following day.
                        let next = (day + 1) % 7
                        register(center, "schedule_\(group.id)_\(day)_b",
                                 startH: 0, startMin: 0, endH: e.h, endMin: e.m, weekday: next + 1)
                    }
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

    /// Today's used self-serve unlocks for a group (device-local day).
    static func quotaUsedToday(groupId: String, grants: [RemoteGrant], now: Date = Date()) -> Int {
        let dayStart = Calendar.current.startOfDay(for: now)
        return grants.filter {
            $0.groupId == groupId && $0.source == "device_quota" && $0.status != "cancelled"
                && (ISO.date($0.startsAt).map { $0 >= dayStart } ?? false)
        }.count
    }

    /// Direct unlock from the shield (quota/open modes). Creates the grant locally,
    /// queues it for server upload, lifts shields, and best-effort schedules re-block.
    /// Returns false when the mode/quota forbids it.
    @discardableResult
    static func unlockFromShield(groupId: String, appToken: ApplicationToken? = nil, now: Date = Date()) -> Bool {
        guard let group = AppGroupStore.groups.first(where: { $0.id == groupId }) else { return false }
        let all = AppGroupStore.grants + AppGroupStore.pendingLocalGrants
        switch group.mode {
        case "quota":
            guard quotaUsedToday(groupId: groupId, grants: all, now: now) < group.quotaPerDay else { return false }
        case "open":
            break
        default:
            return false // strict: chat is the only door
        }
        let iso = ISO8601DateFormatter()
        let expires = now.addingTimeInterval(TimeInterval(group.quotaMinutes * 60))
        // Tapped on a specific app? Scope the hole to that app alone.
        if let appToken {
            var exemptions = AppGroupStore.tokenExemptions.filter { $0.value > now } // prune
            exemptions[appToken] = expires
            AppGroupStore.tokenExemptions = exemptions
        }
        let grant = RemoteGrant(
            id: UUID().uuidString.lowercased(), groupId: groupId, minutes: group.quotaMinutes,
            reason: appToken != nil ? singleAppReason : "Unlocked at the shield",
            startsAt: iso.string(from: now),
            expiresAt: iso.string(from: expires), status: "active", source: "device_quota",
            updatedAt: iso.string(from: now))
        AppGroupStore.grants = AppGroupStore.grants + [grant]
        AppGroupStore.pendingLocalGrants = AppGroupStore.pendingLocalGrants + [grant]
        applyAllImmediateShields(policies: AppGroupStore.policies, grants: AppGroupStore.grants, now: now)
        // Best-effort re-block timer; the app/NSE/monitor reconcile is the backstop.
        let cal = Calendar.current
        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now),
            intervalEnd: cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: expires),
            repeats: false)
        try? DeviceActivityCenter().startMonitoring(.init("grantend_\(groupId)"), during: schedule)
        AppGroupStore.appendEvent(DeviceEvent(type: "grant_started", groupId: groupId, meta: ["minutes": group.quotaMinutes]))
        return true
    }

    /// Most-specific group containing this app token: dedicated per-app groups
    /// (fewest apps) win attribution over broad ones, so their mode/quota govern.
    static func groupContaining(appToken: ApplicationToken) -> String? {
        var best: (id: String, size: Int)?
        for group in AppGroupStore.groups {
            guard let sel = AppGroupStore.selection(for: group.id),
                  sel.applicationTokens.contains(appToken) else { continue }
            let size = sel.applicationTokens.count
            if best == nil || size < best!.size { best = (group.id, size) }
        }
        return best?.id
    }

    static func hasContent(_ s: FamilyActivitySelection) -> Bool {
        !s.applicationTokens.isEmpty || !s.categoryTokens.isEmpty
    }

    private static func clock(_ s: String?) -> (h: Int, m: Int)? {
        guard let total = hhmm(s) else { return nil }
        return (total / 60, total % 60)
    }

    private static func register(_ center: DeviceActivityCenter, _ name: String,
                                 startH: Int, startMin: Int, endH: Int, endMin: Int, weekday: Int) {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: startH, minute: startMin, weekday: weekday),
            intervalEnd: DateComponents(hour: endH, minute: endMin, weekday: weekday),
            repeats: true
        )
        try? center.startMonitoring(.init(name), during: schedule)
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
