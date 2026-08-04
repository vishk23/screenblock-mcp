import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            Tracker.shared.start()
            Blocker.shared.start()
            MacSync.shared.start()
        }
    }
}

@main
struct ScreenCPMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra(Brand.name, systemImage: "hourglass") {
            SpikeMenu()
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Edit Group", for: String.self) { $groupId in
            if let groupId { GroupEditorView(groupId: groupId) }
        }
        .windowResizability(.contentSize)
    }
}

struct SpikeMenu: View {
    @ObservedObject private var tracker = Tracker.shared
    @ObservedObject private var blocker = Blocker.shared
    @ObservedObject private var sync = MacSync.shared
    @ObservedObject private var today = MacToday.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showDetails = false

    private func statusLine(for group: RemoteGroup) -> (String, Color) {
        let sel = sync.selections[group.id, default: []]
        guard !sel.isEmpty else { return ("not mapped on this Mac", .orange) }
        if let grant = MacEnforcement.activeGrant(for: group.id, in: sync.grants),
           let until = ISO.date(grant.expiresAt) {
            return ("open until \(until.formatted(date: .omitted, time: .shortened))", .green)
        }
        let blocked = !sel.isDisjoint(with: blocker.blockedBundleIds)
        return (blocked ? "blocked · \(sel.count) apps" : "\(sel.count) apps", blocked ? .red : .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "hourglass").foregroundStyle(.tint)
                Text(Brand.name).font(.headline)
                Spacer()
            }

            if let d = today.day {
                let f = d.earning.focusedMacMinutesToday
                LabeledContent {
                    Text(f >= 60 ? "\(f / 60)h \(f % 60)m" : "\(f)m")
                        .font(.title3.bold().monospacedDigit()).foregroundStyle(.green)
                } label: { Label("Focused today", systemImage: "laptopcomputer") }

                ForEach(d.earning.rules, id: \.group) { r in
                    if let toGo = r.minutesToNextReward {
                        VStack(alignment: .leading, spacing: 2) {
                            ProgressView(value: Double(max(0, r.thresholdMinutes - toGo)), total: Double(r.thresholdMinutes))
                                .tint(.green)
                            Text(toGo == 0 ? "\(r.group) reward ready 🎉"
                                 : "\(toGo) more min → \(r.rewardMinutes) min of \(r.group)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
            }

            if !sync.groups.isEmpty {
                Text("Groups").font(.subheadline.bold())
                ForEach(sync.groups) { group in
                    let status = statusLine(for: group)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                            Text(status.0).font(.caption).foregroundStyle(status.1)
                        }
                        Spacer()
                        Button("Edit") {
                            openWindow(value: group.id)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
                LabeledContent("Server sync",
                               value: sync.lastSync.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                if let err = sync.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
                Divider()
            }

            DisclosureGroup("Details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Frontmost", value: tracker.currentApp)
                    LabeledContent("Kills today", value: "\(blocker.killCount)")
                    if !blocker.blockedBundleIds.isEmpty {
                        Text("Blocked now").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(blocker.blockedBundleIds.sorted(), id: \.self) { bid in
                            HStack {
                                Text(bid).font(.caption).lineLimit(1)
                                Spacer()
                                Button("Unblock") { blocker.toggleBlock(bundleId: bid) }.controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)

            Divider()
            Button("Quit \(Brand.name)") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
        .task { await today.load() }
    }
}
