import SwiftUI

/// The moment at the wall: reason-required self-serve unlock.
/// Designed to be swappable for an API-judge micro-negotiation later —
/// same entry points, smarter gatekeeper.
struct UnlockSheet: View {
    let group: RemoteGroup
    @ObservedObject var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var reason = ""
    @State private var submitting = false
    @State private var denial: String?

    private static let cannedReasons = ["Got a DM", "Need it for work", "Quick check-in"]

    private var quotaUsedToday: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return sync.grants.filter {
            $0.groupId == group.id && $0.source == "device_quota" && $0.status != "cancelled"
                && (ISO.date($0.startsAt).map { $0 >= today } ?? false)
        }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                if group.mode == "quota" {
                    Section {
                        LabeledContent("Unlocks left today",
                                       value: "\(max(0, group.quotaPerDay - quotaUsedToday)) of \(group.quotaPerDay)")
                        LabeledContent("Duration", value: "\(group.quotaMinutes) min")
                    }
                }
                Section("Why do you need \(group.name) right now?") {
                    ForEach(Self.cannedReasons, id: \.self) { canned in
                        Button {
                            reason = canned
                        } label: {
                            HStack {
                                Text(canned)
                                Spacer()
                                if reason == canned { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    TextField("Or type your own…", text: $reason, axis: .vertical)
                }
                if let denial {
                    Section { Text(denial).foregroundStyle(.red) }
                }
                Section {
                    Button(submitting ? "Requesting…" : "Unlock") { submit() }
                        .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                } footer: {
                    Text("Your reason is logged — your coach sees it. The friction is the feature.")
                }
            }
            .navigationTitle("Request time")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func submit() {
        submitting = true
        denial = nil
        Task {
            do {
                let result = try await BackendClient.live.requestUnlock(
                    groupId: group.id, reason: reason.trimmingCharacters(in: .whitespaces))
                // Apply instantly on-device; sync will reconcile with the server copy.
                AppGroupStore.grants = AppGroupStore.grants + [result.grant]
                EnforcementEngine.applyAllImmediateShields(
                    policies: AppGroupStore.policies, grants: AppGroupStore.grants)
                EnforcementEngine.reconcileSchedules(
                    groups: AppGroupStore.groups, policies: AppGroupStore.policies, grants: AppGroupStore.grants)
                await sync.syncNow()
                dismiss()
            } catch let denied as BackendClient.UnlockDenied {
                denial = denied.message
            } catch {
                denial = "Couldn't reach the server. Check your connection."
            }
            submitting = false
        }
    }
}
