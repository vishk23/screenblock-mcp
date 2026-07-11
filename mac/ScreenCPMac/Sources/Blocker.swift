import AppKit
import Combine

/// M0 spike: userspace app blocking — the industry-standard Mac pattern
/// (Focus, Opal, Jomo all do this): blocked app launches/activates → terminate.
/// Requires a non-sandboxed app; sub-second flash before the quit is expected.
@MainActor
final class Blocker: ObservableObject {
    static let shared = Blocker()

    /// Manual quick-blocks from the menu (in-memory).
    @Published var manualBlocked: Set<String> = []
    /// Synced from the server every 30s (groups × policies × grants).
    @Published private(set) var serverBlocked: Set<String> = []

    var blockedBundleIds: Set<String> { manualBlocked.union(serverBlocked) }

    func applyServerBlocklist(_ blocked: Set<String>) {
        let added = !blocked.subtracting(serverBlocked).isEmpty
        serverBlocked = blocked.subtracting(Self.protected)
        if added { sweep() }
    }

    /// Never-blockable: ourselves and apps whose loss bricks the session.
    static let protected: Set<String> = [
        Bundle.main.bundleIdentifier?.lowercased() ?? "com.vishnukchitti.screencp.mac",
        "com.apple.finder", "com.apple.systempreferences", "com.apple.systemsettings",
        "com.apple.dock", "com.apple.loginwindow",
    ]
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
        guard !Self.protected.contains(bid), !bid.isEmpty else { return }
        if manualBlocked.contains(bid) {
            manualBlocked.remove(bid)
        } else {
            manualBlocked.insert(bid)
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
        // Same coaching signal as the iPhone shield: user bumped into a block.
        MacSync.shared.enqueue(MacEvent(
            type: "shield_shown",
            groupId: MacSync.shared.groupId(forBundleId: bid),
            meta: ["platform": "mac", "app": app.localizedName ?? bid]))
    }
}
