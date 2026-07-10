import Foundation

/// Core sync pipeline, callable from UI (SyncCoordinator) and background push (AppDelegate).
/// Pull → persist → enforce → ack → report selections → upload events.
enum SyncService {
    @discardableResult
    static func syncNow() async -> String? {
        let client = BackendClient.live
        do {
            try await client.register(apnsToken: AppGroupStore.deviceToken)

            // Shield-created grants first, so the pull below reflects them.
            var stillPending: [RemoteGrant] = []
            for grant in AppGroupStore.pendingLocalGrants {
                do { try await client.postDeviceGrant(grant) }
                catch { stillPending.append(grant) }
            }
            AppGroupStore.pendingLocalGrants = stillPending

            let payload = try await client.sync(since: nil)

            AppGroupStore.groups = payload.groups
            AppGroupStore.policies = payload.policies.filter(\.active)
            // Merge any still-unuploaded shield grants so enforcement honors them.
            var grants = payload.grants
            grants.append(contentsOf: stillPending.filter { p in !grants.contains { $0.id == p.id } })
            AppGroupStore.grants = grants

            EnforcementEngine.reconcileAll()

            try await client.ack(apnsToken: AppGroupStore.deviceToken, appliedThrough: payload.serverTime)
            AppGroupStore.lastSyncServerTime = payload.serverTime

            for group in payload.groups {
                let has = AppGroupStore.selection(for: group.id).map(EnforcementEngine.hasContent) ?? false
                if has != group.hasSelection {
                    try? await client.reportSelection(groupId: group.id, hasSelection: has)
                }
            }

            let events = AppGroupStore.drainEvents()
            do { try await client.uploadEvents(events) }
            catch { AppGroupStore.requeueEvents(events) }

            return nil
        } catch {
            return String(describing: error)
        }
    }
}
