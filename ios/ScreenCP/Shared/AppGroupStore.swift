import Foundation
import FamilyControls

/// Shared state between the main app and the monitor extension,
/// persisted in App Group UserDefaults.
enum AppGroupStore {
    static let suite = UserDefaults(suiteName: "group.com.vishnukchitti.screencp")!

    // MARK: group name→apps selections (device is source of truth for these)

    static func selection(for groupId: String) -> FamilyActivitySelection? {
        guard let data = suite.data(forKey: "selection_\(groupId)") else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    static func setSelection(_ selection: FamilyActivitySelection, for groupId: String) {
        suite.set(try? JSONEncoder().encode(selection), forKey: "selection_\(groupId)")
    }

    // MARK: synced policy snapshot (extension reads these to act at interval boundaries)

    static var policies: [RemotePolicy] {
        get { decode("policies") ?? [] }
        set { suite.set(try? JSONEncoder().encode(newValue), forKey: "policies") }
    }

    static var grants: [RemoteGrant] {
        get { decode("grants") ?? [] }
        set { suite.set(try? JSONEncoder().encode(newValue), forKey: "grants") }
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

    /// Stable pseudo-token identifying this install until real APNs registration (M4).
    static var deviceToken: String {
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
