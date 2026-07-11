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
        MenuBarExtra("ScreenCP", systemImage: "hourglass") {
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
    @Environment(\.openWindow) private var openWindow

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
            Text("ScreenCP Mac").font(.headline)

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

            LabeledContent("Frontmost", value: tracker.currentApp)
            LabeledContent("Idle", value: String(format: "%.0fs", tracker.idleSeconds))
            LabeledContent("Kills", value: "\(blocker.killCount) (\(blocker.lastKill))")

            Divider()
            Text("This session").font(.subheadline.bold())
            ForEach(tracker.secondsByApp.sorted { $0.value > $1.value }.prefix(5), id: \.key) { name, secs in
                LabeledContent(name, value: secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs)s")
            }

            Divider()
            Text("Blocked apps").font(.subheadline.bold())
            if blocker.blockedBundleIds.isEmpty {
                Text("None — switch to an app, then block it from here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Unblock must NOT depend on the app being frontmost — a blocked app
            // can never become frontmost (we kill it). List with buttons instead.
            ForEach(blocker.blockedBundleIds.sorted(), id: \.self) { bid in
                HStack {
                    Text(bid).font(.caption)
                    Spacer()
                    Button("Unblock") { blocker.toggleBlock(bundleId: bid) }
                }
            }
            if !Blocker.protected.contains(tracker.currentBundleId.lowercased()),
               !blocker.blockedBundleIds.contains(tracker.currentBundleId.lowercased()) {
                Button("Block \(tracker.currentApp)") {
                    blocker.toggleBlock(bundleId: tracker.currentBundleId)
                }
                .disabled(tracker.currentBundleId.isEmpty)
            }

            Divider()
            Button("Quit ScreenCP Mac") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }
}
