import Foundation
import FamilyControls

/// Shared state between the main app and the monitor extension,
/// persisted in App Group UserDefaults.
enum AppGroupStore {
    static let suite = UserDefaults(suiteName: "group.com.vishnukchitti.screencp")!

    /// Extensions (shield config/action) live for milliseconds — buffered
    /// UserDefaults writes die with the process unless forced to disk.
    static func flush() { suite.synchronize() }

    // MARK: group name→apps selections (device is source of truth for these)

    static func selection(for groupId: String) -> FamilyActivitySelection? {
        guard let data = suite.data(forKey: "selection_\(groupId)") else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    static func setSelection(_ selection: FamilyActivitySelection, for groupId: String) {
        suite.set(try? JSONEncoder().encode(selection), forKey: "selection_\(groupId)")
        flush()
    }

    // MARK: synced policy snapshot (extension reads these to act at interval boundaries)

    static var policies: [RemotePolicy] {
        get { decode("policies") ?? [] }
        set { suite.set(try? JSONEncoder().encode(newValue), forKey: "policies") }
    }

    static var grants: [RemoteGrant] {
        get { decode("grants") ?? [] }
        set { suite.set(try? JSONEncoder().encode(newValue), forKey: "grants"); flush() }
    }

    /// Grants created BY extensions at the shield, awaiting upload to the server.
    static var pendingLocalGrants: [RemoteGrant] {
        get { decode("pendingLocalGrants") ?? [] }
        set { suite.set(try? JSONEncoder().encode(newValue), forKey: "pendingLocalGrants"); flush() }
    }

    static var groups: [RemoteGroup] {
        get { decode("groups") ?? [] }
        set { suite.set(try? JSONEncoder().encode(newValue), forKey: "groups") }
    }

    // MARK: event queue (extension appends, app uploads)

    static func appendEvent(_ event: DeviceEvent) {
        var queue: [DeviceEvent] = decode("eventQueue") ?? []
        queue.append(event)
        suite.set(try? JSONEncoder().encode(queue), forKey: "eventQueue")
        flush()
    }

    static func drainEvents() -> [DeviceEvent] {
        let queue: [DeviceEvent] = decode("eventQueue") ?? []
        suite.removeObject(forKey: "eventQueue")
        return queue
    }

    static func requeueEvents(_ events: [DeviceEvent]) {
        var queue: [DeviceEvent] = decode("eventQueue") ?? []
        queue.insert(contentsOf: events, at: 0)
        suite.set(try? JSONEncoder().encode(queue), forKey: "eventQueue")
    }

    // MARK: sync bookkeeping

    static var lastSyncServerTime: String? {
        get { suite.string(forKey: "lastSyncServerTime") }
        set { suite.set(newValue, forKey: "lastSyncServerTime") }
    }

    /// Real APNs token (hex), set once registration succeeds.
    static var apnsToken: String? {
        get { suite.string(forKey: "apnsToken") }
        set { suite.set(newValue, forKey: "apnsToken") }
    }

    /// Token this device is known by server-side: real APNs token when available,
    /// otherwise a stable local pseudo-token (pre-push installs, simulators).
    static var deviceToken: String {
        if let t = apnsToken { return t }
        if let t = suite.string(forKey: "deviceToken") { return t }
        let t = "local-\(UUID().uuidString)"
        suite.set(t, forKey: "deviceToken")
        return t
    }

    private static func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = suite.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
