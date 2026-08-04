import UserNotifications
import ManagedSettings
import Foundation

/// Runs on delivery of any mutable-content push — BEFORE and WITHOUT any tap,
/// and (unlike silent push) even if the app was force-quit.
/// Spike M1: attempt full sync + shield application from here. If it works,
/// the notification is rewritten to say so; if not, it stays "Tap to apply".
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
        self.content = content

        Task {
            let applied = await Self.syncAndApply()
            if applied, let content {
                content.title = Brand.name
                // Keep the human message (celebrations, re-locks); the check mark
                // signals it's already applied — no tap needed.
                content.body = "✓ \(content.body)"
            }
            contentHandler(content ?? request.content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Out of time — deliver as-is (stays "Tap to apply").
        if let content { contentHandler?(content) }
    }

    /// Mirror of SyncService.syncNow, minus DeviceActivity scheduling (untested
    /// from this context) — immediate shields are the time-critical part.
    private static func syncAndApply() async -> Bool {
        guard let url = URL(string: "\(Secrets.baseURL)/device/sync") else { return false }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(SyncPayload.self, from: data)
        else { return false }

        AppGroupStore.groups = payload.groups
        AppGroupStore.policies = payload.policies.filter(\.active)
        AppGroupStore.grants = payload.grants

        for group in payload.groups {
            EnforcementEngine.applyImmediateShield(
                groupId: group.id, policies: AppGroupStore.policies, grants: AppGroupStore.grants)
        }
        // Re-block timers for any live grants (registration may or may not be
        // permitted from this context — the server's expiry poke is the backstop).
        EnforcementEngine.scheduleGrantEndTimers()

        // Upload any evidence stranded by the network-less shield extensions.
        let events = AppGroupStore.drainEvents()
        if !events.isEmpty {
            var evReq = URLRequest(url: URL(string: "\(Secrets.baseURL)/device/events")!)
            evReq.httpMethod = "POST"
            evReq.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
            evReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            evReq.httpBody = try? JSONEncoder().encode(["events": events])
            if (try? await URLSession.shared.data(for: evReq)) == nil {
                AppGroupStore.requeueEvents(events)
            }
        }
        // Upload shield-created grants awaiting the server.
        for grant in AppGroupStore.pendingLocalGrants {
            var gReq = URLRequest(url: URL(string: "\(Secrets.baseURL)/device/grants")!)
            gReq.httpMethod = "POST"
            gReq.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
            gReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            gReq.httpBody = try? JSONSerialization.data(withJSONObject: [
                "groupId": grant.groupId, "reason": grant.reason ?? "Unlocked at the shield",
                "minutes": grant.minutes, "id": grant.id, "startsAt": grant.startsAt,
            ])
            if let (_, resp) = try? await URLSession.shared.data(for: gReq),
               let code = (resp as? HTTPURLResponse)?.statusCode, code == 200 || code == 403 {
                AppGroupStore.pendingLocalGrants.removeAll { $0.id == grant.id }
            }
        }

        // Ack so the server's fallback logic knows we applied.
        var ackReq = URLRequest(url: URL(string: "\(Secrets.baseURL)/device/ack")!)
        ackReq.httpMethod = "POST"
        ackReq.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
        ackReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ackReq.httpBody = try? JSONSerialization.data(withJSONObject: [
            "apnsToken": AppGroupStore.deviceToken,
            "appliedThrough": payload.serverTime,
        ])
        _ = try? await URLSession.shared.data(for: ackReq)
        return true
    }
}
