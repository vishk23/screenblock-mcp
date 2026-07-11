import Foundation

/// Device-API client — the Mac is just another device on the same server.
struct MacBackend {
    static let base = URL(string: Secrets.baseURL)!

    /// Stable per-install pseudo-token ("mac-…"): Macs poll rather than receive APNs.
    static var deviceToken: String {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "macDeviceToken") { return t }
        let t = "mac-\(UUID().uuidString.lowercased())"
        d.set(t, forKey: "macDeviceToken")
        return t
    }

    private static func request(_ path: String, method: String = "POST", body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(Secrets.deviceBearerToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func register() async throws {
        _ = try await request("device/register",
                              body: try JSONEncoder().encode(["apnsToken": deviceToken]))
    }

    static func sync() async throws -> SyncPayload {
        let data = try await request("device/sync", method: "GET")
        return try JSONDecoder().decode(SyncPayload.self, from: data)
    }

    static func ack(serverTime: String) async throws {
        _ = try await request("device/ack",
                              body: try JSONEncoder().encode(["apnsToken": deviceToken, "appliedThrough": serverTime]))
    }

    static func uploadEvents(_ events: [MacEvent]) async throws {
        guard !events.isEmpty else { return }
        struct Body: Encodable { let events: [MacEvent] }
        _ = try await request("device/events", body: try JSONEncoder().encode(Body(events: events)))
    }
}
