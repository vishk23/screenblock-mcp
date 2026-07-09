import Foundation

/// Thin client for the ScreenCP device API (server/src/deviceApi.ts).
struct BackendClient {
    let baseURL: URL
    let deviceToken: String // DEVICE_BEARER_TOKEN

    static var live: BackendClient {
        BackendClient(baseURL: URL(string: Secrets.baseURL)!, deviceToken: Secrets.deviceBearerToken)
    }

    private func request(_ path: String, method: String = "POST", body: (any Encodable)? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func register(apnsToken: String) async throws {
        struct Body: Encodable { let apnsToken: String }
        _ = try await request("device/register", body: Body(apnsToken: apnsToken))
    }

    func sync(since: String?) async throws -> SyncPayload {
        var path = "device/sync"
        if let since, let escaped = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?since=\(escaped)"
        }
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(SyncPayload.self, from: data)
    }

    func ack(apnsToken: String, appliedThrough: String) async throws {
        struct Body: Encodable { let apnsToken: String; let appliedThrough: String }
        _ = try await request("device/ack", body: Body(apnsToken: apnsToken, appliedThrough: appliedThrough))
    }

    func uploadEvents(_ events: [DeviceEvent]) async throws {
        guard !events.isEmpty else { return }
        struct Body: Encodable { let events: [DeviceEvent] }
        _ = try await request("device/events", body: Body(events: events))
    }

    func reportSelection(groupId: String, hasSelection: Bool) async throws {
        struct Body: Encodable { let hasSelection: Bool }
        _ = try await request("device/groups/\(groupId)/selection", body: Body(hasSelection: hasSelection))
    }
}
