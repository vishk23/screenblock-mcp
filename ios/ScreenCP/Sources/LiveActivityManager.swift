import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts a Live Activity when a grant becomes active, ends it at expiry.
/// Reconciled on every sync so the Lock Screen countdown always matches reality.
enum LiveActivityManager {

    static func reconcile(groups: [RemoteGroup], grants: [RemoteGrant], now: Date = Date()) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Active, non-single-app grants worth showing a countdown for.
        let live = grants.filter { g in
            (g.status == "pending" || g.status == "active")
                && g.reason != EnforcementEngine.singleAppReason
                && (ISO.date(g.expiresAt).map { $0 > now } ?? false)
        }
        let liveIds = Set(live.map(\.id))
        let running = Activity<GrantActivityAttributes>.activities

        // End activities whose grant is gone/expired.
        for activity in running where !liveIds.contains(activity.attributes.grantId) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }

        // Start activities for newly-live grants.
        let runningIds = Set(running.map { $0.attributes.grantId })
        for grant in live where !runningIds.contains(grant.id) {
            guard let expires = ISO.date(grant.expiresAt) else { continue }
            let name = groups.first { $0.id == grant.groupId }?.name ?? "App"
            let attrs = GrantActivityAttributes(groupName: name, grantId: grant.id)
            let state = GrantActivityAttributes.ContentState(expiresAt: expires)
            _ = try? Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: expires),
                pushType: nil)
        }
        #endif
    }
}
