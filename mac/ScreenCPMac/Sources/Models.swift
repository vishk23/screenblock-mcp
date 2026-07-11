import Foundation

// Mirrors server/src/types.ts (source of truth: ios/ScreenCP/Shared/Models.swift).

struct RemoteGroup: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let hasSelection: Bool
    let mode: String        // "strict" | "quota" | "open"
    let quotaPerDay: Int
    let quotaMinutes: Int
    let updatedAt: String
}

struct RemotePolicy: Codable, Identifiable, Hashable {
    let id: String
    let groupId: String
    let kind: String // "schedule" | "limit" | "block"
    let active: Bool
    let daysOfWeek: [Int]?
    let startTime: String?
    let endTime: String?
    let minutesPerDay: Int?
    let until: String?
    let timezone: String?
    let updatedAt: String
}

struct RemoteGrant: Codable, Identifiable, Hashable {
    let id: String
    let groupId: String
    let minutes: Int
    let reason: String?
    let startsAt: String
    let expiresAt: String
    let status: String
    let source: String
    let updatedAt: String
}

struct SyncPayload: Codable {
    let groups: [RemoteGroup]
    let policies: [RemotePolicy]
    let grants: [RemoteGrant]
    let serverTime: String
}

struct MacEvent: Codable {
    let type: String
    let groupId: String?
    let ts: String
    let meta: [String: String]

    init(type: String, groupId: String?, meta: [String: String] = [:]) {
        self.type = type
        self.groupId = groupId
        self.ts = ISO8601DateFormatter().string(from: Date())
        self.meta = meta
    }
}

enum ISO {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
    static func date(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}
