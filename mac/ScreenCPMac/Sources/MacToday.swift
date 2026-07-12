import Foundation
import Combine

struct MacDaySummary: Codable {
    struct MacUsage: Codable, Hashable { let app: String; let minutes: Int }
    struct EarnRuleStatus: Codable, Hashable {
        let group: String; let thresholdMinutes: Int; let rewardMinutes: Int
        let earnedToday: Int; let maxPerDay: Int; let minutesToNextReward: Int?
    }
    struct Summary: Codable { let shieldShown: [String: Int]; let macUsage: [MacUsage] }
    struct Earning: Codable { let focusedMacMinutesToday: Int; let rules: [EarnRuleStatus] }
    let summary: Summary
    let earning: Earning
}

@MainActor
final class MacToday: ObservableObject {
    static let shared = MacToday()
    @Published var day: MacDaySummary?

    func load() async {
        guard let url = URL(string: "\(Secrets.baseURL)/device/summary") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(MacDaySummary.self, from: data) else { return }
        day = decoded
    }
}

import AppKit
extension NSWorkspace {
    func icon(forBundleId bid: String) -> NSImage? {
        guard let url = urlForApplication(withBundleIdentifier: bid) else { return nil }
        return icon(forFile: url.path)
    }
}
