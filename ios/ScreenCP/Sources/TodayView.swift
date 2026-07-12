import SwiftUI

struct DaySummary: Codable {
    struct MacUsage: Codable, Hashable { let app: String; let minutes: Int }
    struct EarnRuleStatus: Codable, Hashable {
        let group: String; let thresholdMinutes: Int; let rewardMinutes: Int
        let earnedToday: Int; let maxPerDay: Int; let minutesToNextReward: Int?
    }
    struct Summary: Codable {
        let shieldShown: [String: Int]
        let macUsage: [MacUsage]
    }
    struct Earning: Codable { let focusedMacMinutesToday: Int; let rules: [EarnRuleStatus] }
    struct ActiveGrant: Codable, Hashable { let group: String; let expiresAt: String; let reason: String? }
    let summary: Summary
    let earning: Earning
    let activeGrants: [ActiveGrant]
}

@MainActor
final class TodayModel: ObservableObject {
    @Published var day: DaySummary?
    func load() async {
        guard let url = URL(string: "\(Secrets.baseURL)/device/summary") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(DaySummary.self, from: data) else { return }
        day = decoded
    }
}

/// The glanceable "Today" — the app opens to this, not a settings list.
struct TodayView: View {
    let day: DaySummary

    var body: some View {
        Section("Today") {
            let focused = day.earning.focusedMacMinutesToday
            LabeledContent {
                Text(focused >= 60 ? "\(focused / 60)h \(focused % 60)m" : "\(focused)m")
                    .font(.title3.bold().monospacedDigit())
            } label: {
                Label("Focused on Mac", systemImage: "laptopcomputer")
            }

            let hits = day.summary.shieldShown.values.reduce(0, +)
            if hits > 0 {
                Label("\(hits) shield\(hits == 1 ? "" : "s") hit today", systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
            }

            ForEach(day.activeGrants, id: \.self) { g in
                if let until = ISO.date(g.expiresAt) {
                    HStack {
                        Label(g.group, systemImage: "hourglass").foregroundStyle(.green)
                        Spacer()
                        Text(until, style: .timer).monospacedDigit().foregroundStyle(.green)
                    }
                }
            }
        }

        if !day.earning.rules.isEmpty {
            Section("Earn your breaks") {
                ForEach(day.earning.rules, id: \.self) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.group).font(.subheadline.bold())
                            Spacer()
                            Text("\(r.earnedToday)/\(r.maxPerDay) earned")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let toGo = r.minutesToNextReward {
                            ProgressView(value: Double(max(0, r.thresholdMinutes - toGo)),
                                         total: Double(r.thresholdMinutes))
                                .tint(.green)
                            Text(toGo == 0 ? "Reward ready 🎉" : "\(toGo) more focused min → \(r.rewardMinutes) min of \(r.group)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("All \(r.maxPerDay) rewards earned today ✓")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if !day.summary.macUsage.isEmpty {
            Section("Mac time today") {
                ForEach(day.summary.macUsage.prefix(5), id: \.self) { u in
                    LabeledContent(u.app, value: u.minutes >= 60 ? "\(u.minutes / 60)h \(u.minutes % 60)m" : "\(u.minutes)m")
                }
            }
        }
    }
}
