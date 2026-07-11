import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            Tracker.shared.start()
            Blocker.shared.start()
        }
    }
}

@main
struct ScreenCPMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ScreenCP", systemImage: "hourglass") {
            SpikeMenu()
        }
        .menuBarExtraStyle(.window)
    }
}

struct SpikeMenu: View {
    @ObservedObject private var tracker = Tracker.shared
    @ObservedObject private var blocker = Blocker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ScreenCP Mac — M0 spike").font(.headline)

            LabeledContent("Frontmost", value: tracker.currentApp)
            LabeledContent("Idle", value: String(format: "%.0fs", tracker.idleSeconds))
            LabeledContent("Kills", value: "\(blocker.killCount) (\(blocker.lastKill))")

            Divider()
            Text("This session").font(.subheadline.bold())
            ForEach(tracker.secondsByApp.sorted { $0.value > $1.value }.prefix(5), id: \.key) { name, secs in
                LabeledContent(name, value: secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs)s")
            }

            Divider()
            Text("Blocked: \(blocker.blockedBundleIds.sorted().joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
            Button(blocker.blockedBundleIds.contains(tracker.currentBundleId.lowercased())
                   ? "Unblock \(tracker.currentApp)"
                   : "Block \(tracker.currentApp)") {
                blocker.toggleBlock(bundleId: tracker.currentBundleId)
            }
            .disabled(tracker.currentBundleId.isEmpty)

            Divider()
            Button("Quit ScreenCP Mac") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }
}
