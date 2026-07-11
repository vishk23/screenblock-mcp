import AppKit
import Combine

/// M0 spike: frontmost-app tracking + AFK detection.
/// Pattern cribbed from ActivityWatch's aw-watcher-window (MPL-2.0):
/// NSWorkspace activation notifications + polling belt-and-suspenders.
/// App names only for now — window titles (Accessibility) come in M2.
@MainActor
final class Tracker: ObservableObject {
    static let shared = Tracker()

    @Published private(set) var currentApp = "—"
    @Published private(set) var currentBundleId = ""
    @Published private(set) var idleSeconds: Double = 0
    /// Foreground seconds per app this session (AFK time excluded).
    @Published private(set) var secondsByApp: [String: Int] = [:]
    /// Seconds accumulated since the last upload flush (app name -> (bundleId, secs)).
    private(set) var unflushed: [String: (bundleId: String, seconds: Int)] = [:]

    private var timer: Timer?
    static let afkThreshold: Double = 60

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        refreshFrontmost()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    @objc private func activated(_ note: Notification) { refreshFrontmost() }

    private func refreshFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        currentApp = app.localizedName ?? "unknown"
        currentBundleId = app.bundleIdentifier ?? ""
    }

    private func tick() {
        refreshFrontmost() // poll too — notifications alone miss cases (ActivityWatch's finding)
        idleSeconds = Self.systemIdleSeconds()
        if idleSeconds < Self.afkThreshold, currentApp != "—" {
            secondsByApp[currentApp, default: 0] += 1
            let prev = unflushed[currentApp]?.seconds ?? 0
            unflushed[currentApp] = (currentBundleId, prev + 1)
        }
    }

    /// Hands the accumulated usage to the uploader and resets the buffer.
    func drainUnflushed(minSeconds: Int = 15) -> [(app: String, bundleId: String, seconds: Int)] {
        let out = unflushed
            .filter { $0.value.seconds >= minSeconds }
            .map { (app: $0.key, bundleId: $0.value.bundleId, seconds: $0.value.seconds) }
        unflushed = [:]
        return out
    }

    /// No permission required (returns an aggregate, not event contents).
    /// kCGAnyInputEventType doesn't round-trip through Swift's CGEventType,
    /// so take the min across the input types that matter.
    static func systemIdleSeconds() -> Double {
        let types: [CGEventType] = [
            .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .otherMouseDown,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
    }
}
