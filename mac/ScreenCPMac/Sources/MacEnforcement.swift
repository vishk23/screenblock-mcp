import Foundation

/// Pure policy → blocked-bundle-ids computation (Mac analog of the iOS engine).
enum MacEnforcement {

    /// Phone-side single-app shield unlocks must NOT open the whole group here.
    static let singleAppReason = "Unlocked at the shield (this app only)"

    static func activeGrant(for groupId: String, in grants: [RemoteGrant], now: Date = Date()) -> RemoteGrant? {
        grants.first { g in
            g.groupId == groupId
                && g.reason != singleAppReason
                && (g.status == "pending" || g.status == "active")
                && (ISO.date(g.expiresAt).map { $0 > now } ?? false)
        }
    }

    /// Effective blocked set: for every group mapped to Mac apps, blocked when a
    /// block policy or an active schedule window applies — unless a grant is live.
    /// (Daily limits need Mac-side usage accrual — M3.)
    static func blockedBundleIds(
        groups: [RemoteGroup],
        policies: [RemotePolicy],
        grants: [RemoteGrant],
        selections: [String: Set<String>],
        now: Date = Date()
    ) -> Set<String> {
        var blocked = Set<String>()
        for group in groups {
            guard let sel = selections[group.id], !sel.isEmpty else { continue }
            if activeGrant(for: group.id, in: grants, now: now) != nil { continue }
            let mine = policies.filter { $0.groupId == group.id && $0.active }
            let hardBlocked = mine.contains { p in
                p.kind == "block" && (p.until == nil || (ISO.date(p.until!).map { $0 > now } ?? true))
            }
            if hardBlocked || scheduleWindowActive(policies: mine, now: now) {
                blocked.formUnion(sel)
            }
        }
        return blocked
    }

    /// Ported from the iOS engine, overnight-window handling included.
    static func scheduleWindowActive(policies: [RemotePolicy], now: Date = Date()) -> Bool {
        let cal = Calendar.current
        let today = cal.component(.weekday, from: now) - 1
        let yesterday = (today + 6) % 7
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        return policies.contains { p in
            guard p.kind == "schedule",
                  let days = p.daysOfWeek,
                  let s = hhmm(p.startTime), let e = hhmm(p.endTime) else { return false }
            if s < e {
                return days.contains(today) && minutes >= s && minutes < e
            }
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
}
