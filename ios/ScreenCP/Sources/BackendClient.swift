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

    struct UnlockResponse: Decodable {
        let grant: RemoteGrant
        let remaining_today: Int?
    }

    struct UnlockDenied: Error {
        let message: String
    }

    /// Self-serve unlock ("the moment at the wall"). Throws UnlockDenied with the
    /// server's human-readable message on 403 (strict mode / quota exhausted).
    func requestUnlock(groupId: String, reason: String, minutes: Int? = nil) async throws -> UnlockResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("device/grants"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let groupId: String; let reason: String; let minutes: Int? }
        req.httpBody = try JSONEncoder().encode(Body(groupId: groupId, reason: reason, minutes: minutes))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 403 {
            struct Denial: Decodable { let message: String? }
            let d = try? JSONDecoder().decode(Denial.self, from: data)
            throw UnlockDenied(message: d?.message ?? "Unlock denied.")
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(UnlockResponse.self, from: data)
    }

    func createGroup(name: String) async throws {
        struct Body: Encodable { let name: String }
        _ = try await request("device/groups", body: Body(name: name))
    }

    func reportSelection(groupId: String, hasSelection: Bool) async throws {
        struct Body: Encodable { let hasSelection: Bool }
        _ = try await request("device/groups/\(groupId)/selection", body: Body(hasSelection: hasSelection))
    }
}
