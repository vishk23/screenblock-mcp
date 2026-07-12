import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared between the app (starts/stops activities) and the widget (renders them).
/// A live grant countdown: "TikTok — 12:40 left" ticking down on the Lock Screen
/// and in the Dynamic Island. The countdown itself is driven by Text(timerInterval:),
/// so it needs no push updates — it stays exact even offline.
public struct GrantActivityAttributes: Codable, Hashable {
    public var groupName: String
    public var grantId: String

    public init(groupName: String, grantId: String) {
        self.groupName = groupName
        self.grantId = grantId
    }

    public struct ContentState: Codable, Hashable {
        public var expiresAt: Date
        public init(expiresAt: Date) { self.expiresAt = expiresAt }
    }
}

#if canImport(ActivityKit)
extension GrantActivityAttributes: ActivityAttributes {}
#endif
