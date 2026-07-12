import Foundation

/// UI-facing wrapper around SyncService: publishes synced state for the views.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var lastSync: Date?
    @Published var lastError: String?
    @Published var groups: [RemoteGroup] = []
    @Published var policies: [RemotePolicy] = []
    @Published var grants: [RemoteGrant] = []

    func syncNow() async {
        let error = await SyncService.syncNow()
        groups = AppGroupStore.groups
        policies = AppGroupStore.policies
        grants = AppGroupStore.grants
        lastError = error
        if error == nil { lastSync = Date() }
        LiveActivityManager.reconcile(groups: groups, grants: grants)
    }
}
