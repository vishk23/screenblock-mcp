import AppKit
import Combine

/// M0 spike: userspace app blocking — the industry-standard Mac pattern
/// (Focus, Opal, Jomo all do this): blocked app launches/activates → terminate.
/// Requires a non-sandboxed app; sub-second flash before the quit is expected.
@MainActor
final class Blocker: ObservableObject {
    static let shared = Blocker()

    /// Spike default: Apple News. Add/remove live from the menu.
    @Published var blockedBundleIds: Set<String> = ["com.apple.news"]
    @Published private(set) var killCount = 0
    @Published private(set) var lastKill = "—"

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(check(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(check(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Sweep anything already running when a block is added.
        sweep()
    }

    func toggleBlock(bundleId: String) {
        let bid = bundleId.lowercased()
        if blockedBundleIds.contains(bid) {
            blockedBundleIds.remove(bid)
        } else {
            blockedBundleIds.insert(bid)
            sweep()
        }
    }

    private func sweep() {
        for app in NSWorkspace.shared.runningApplications {
            kill(ifBlocked: app)
        }
    }

    @objc private func check(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        kill(ifBlocked: app)
    }

    private func kill(ifBlocked app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier?.lowercased(), blockedBundleIds.contains(bid) else { return }
        // forceTerminate (not terminate): a polite quit lets apps like Apple News
        // stall for seconds; a blocker wants the flash as short as possible.
        app.forceTerminate()
        killCount += 1
        lastKill = "\(app.localizedName ?? bid) at \(Date().formatted(date: .omitted, time: .standard))"
    }
}
