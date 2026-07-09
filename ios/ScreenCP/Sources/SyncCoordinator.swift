import Foundation

/// Pull → persist → enforce → ack → upload events. The reconcile backstop (spec §7 rung 4).
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var lastSync: Date?
    @Published var lastError: String?
    @Published var groups: [RemoteGroup] = []
    @Published var policies: [RemotePolicy] = []
    @Published var grants: [RemoteGrant] = []

    private let client = BackendClient.live

    func syncNow() async {
        do {
            try await client.register(apnsToken: AppGroupStore.deviceToken)

            // Full pull every time (personal scale — payload is tiny, and it self-heals).
            let payload = try await client.sync(since: nil)

            AppGroupStore.groups = payload.groups
            AppGroupStore.policies = payload.policies.filter(\.active)
            AppGroupStore.grants = payload.grants

            EnforcementEngine.reconcileAll()

            try await client.ack(apnsToken: AppGroupStore.deviceToken, appliedThrough: payload.serverTime)
            AppGroupStore.lastSyncServerTime = payload.serverTime

            // Report selection status so `has_selection` stays truthful server-side.
            for group in payload.groups {
                let has = AppGroupStore.selection(for: group.id).map(EnforcementEngine.hasContent) ?? false
                if has != group.hasSelection {
                    try? await client.reportSelection(groupId: group.id, hasSelection: has)
                }
            }

            // Upload queued events (extension writes them; requeue on failure).
            let events = AppGroupStore.drainEvents()
            do { try await client.uploadEvents(events) }
            catch { AppGroupStore.requeueEvents(events) }

            groups = payload.groups
            policies = payload.policies.filter(\.active)
            grants = payload.grants
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }
}
