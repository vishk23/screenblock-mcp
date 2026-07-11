import AppKit
import Combine

/// Pull → enforce → ack → upload. Macs poll (30s) instead of receiving pushes;
/// also syncs on menu open and after local edits.
@MainActor
final class MacSync: ObservableObject {
    static let shared = MacSync()

    @Published private(set) var groups: [RemoteGroup] = []
    @Published private(set) var policies: [RemotePolicy] = []
    @Published private(set) var grants: [RemoteGrant] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?

    /// groupId → bundle ids mapped on THIS Mac (local, like iOS token selections).
    @Published var selections: [String: Set<String>] = MacSync.loadSelections() {
        didSet { persistSelections() }
    }

    private var timer: Timer?
    private var eventQueue: [MacEvent] = []
    private var lastUsageFlush = Date()
    static let usageFlushInterval: TimeInterval = 300

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        Task { await syncNow() }
    }

    func enqueue(_ event: MacEvent) { eventQueue.append(event) }

    /// bundleId → owning group (for kill-event attribution; smallest group wins,
    /// matching the iPhone's most-specific rule).
    func groupId(forBundleId bid: String) -> String? {
        selections
            .filter { $0.value.contains(bid) }
            .min { $0.value.count < $1.value.count }?
            .key
    }

    func syncNow() async {
        // The insight the iPhone can never provide: real per-app minutes.
        if Date().timeIntervalSince(lastUsageFlush) >= Self.usageFlushInterval {
            lastUsageFlush = Date()
            for entry in Tracker.shared.drainUnflushed() {
                eventQueue.append(MacEvent(type: "app_usage", groupId: groupId(forBundleId: entry.bundleId), meta: [
                    "platform": "mac", "app": entry.app,
                    "bundleId": entry.bundleId, "seconds": String(entry.seconds),
                ]))
            }
        }
        do {
            try await MacBackend.register()
            let payload = try await MacBackend.sync()
            groups = payload.groups
            policies = payload.policies.filter(\.active)
            grants = payload.grants

            let blocked = MacEnforcement.blockedBundleIds(
                groups: groups, policies: policies, grants: grants, selections: selections)
            Blocker.shared.applyServerBlocklist(blocked)

            try await MacBackend.ack(serverTime: payload.serverTime)

            let toSend = eventQueue
            eventQueue = []
            do { try await MacBackend.uploadEvents(toSend) }
            catch { eventQueue.insert(contentsOf: toSend, at: 0) }

            lastSync = Date()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: selection persistence

    private static func loadSelections() -> [String: Set<String>] {
        guard let data = UserDefaults.standard.data(forKey: "macSelections"),
              let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistSelections() {
        UserDefaults.standard.set(try? JSONEncoder().encode(selections), forKey: "macSelections")
    }
}

/// Installed + running apps for the group editor.
struct InstalledApp: Identifiable, Hashable {
    let id: String      // bundle id, lowercased
    let name: String

    static func scan() -> [InstalledApp] {
        var found: [String: String] = [:]
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { continue }
                found[bid.lowercased()] = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bid = app.bundleIdentifier?.lowercased(), found[bid] == nil {
                found[bid] = app.localizedName ?? bid
            }
        }
        for bid in Blocker.protected { found.removeValue(forKey: bid) }
        return found.map { InstalledApp(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
