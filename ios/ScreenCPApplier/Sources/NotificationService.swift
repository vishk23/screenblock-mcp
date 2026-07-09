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
                content.title = "ScreenCP"
                content.body = "✓ Applied automatically — no tap needed"
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
