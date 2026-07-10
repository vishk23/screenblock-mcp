import SwiftUI
import FamilyControls

struct ContentView: View {
    @StateObject private var sync = SyncCoordinator()
    @State private var authStatus = AuthorizationCenter.shared.authorizationStatus
    @State private var unlockGroup: RemoteGroup?
    @State private var setupGroup: RemoteGroup?
    @State private var creatingStarters = false
    @State private var showOnboarding = !AppGroupStore.suite.bool(forKey: "onboarded")
    @Environment(\.scenePhase) private var scenePhase

    /// Shield "Request time" button routes here via the ShieldAction extension.
    private func consumePendingUnlock() {
        guard let gid = AppGroupStore.suite.string(forKey: "pendingUnlockGroupId"), !gid.isEmpty else { return }
        AppGroupStore.suite.removeObject(forKey: "pendingUnlockGroupId")
        unlockGroup = sync.groups.first { $0.id == gid } ?? AppGroupStore.groups.first { $0.id == gid }
    }

    /// "Choose apps for X" nudge (new group created from chat) routes here.
    private func consumePendingSetup() {
        guard let gid = AppGroupStore.suite.string(forKey: "pendingSetupGroupId"), !gid.isEmpty else { return }
        AppGroupStore.suite.removeObject(forKey: "pendingSetupGroupId")
        setupGroup = sync.groups.first { $0.id == gid } ?? AppGroupStore.groups.first { $0.id == gid }
    }

    private func createStarterGroups() {
        creatingStarters = true
        Task {
            for name in ["Social", "Games", "Entertainment"] {
                try? await BackendClient.live.createGroup(name: name)
            }
            await sync.syncNow()
            creatingStarters = false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if authStatus != .approved {
                    Section {
                        Button("Enable Screen Time Access") {
                            Task {
                                try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                                authStatus = AuthorizationCenter.shared.authorizationStatus
                            }
                        }
                    } header: { Text("Setup required") }
                }

                Section("Groups") {
                    if sync.groups.isEmpty {
                        Text("No groups yet. Ask ChatGPT to create one — or start with the basics:")
                            .foregroundStyle(.secondary)
                        Button(creatingStarters ? "Creating…" : "Create starter groups (Social, Games, Entertainment)") {
                            createStarterGroups()
                        }
                        .disabled(creatingStarters)
                    }
                    ForEach(sync.groups) { group in
                        NavigationLink {
                            GroupDetailView(group: group, sync: sync)
                        } label: {
                            GroupRow(group: group, policies: sync.policies)
                        }
                    }
                }

                Section("Sync") {
                    LabeledContent("Last sync", value: sync.lastSync.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                    if let err = sync.lastError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Sync now") { Task { await sync.syncNow() } }
                }

                Section {
                    NavigationLink("Debug: manual shield spike") { SpikeView() }
                }
            }
            .navigationTitle("ScreenCP")
            .refreshable { await sync.syncNow() }
            .task { await sync.syncNow() }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await sync.syncNow()
                        consumePendingUnlock()
                        consumePendingSetup()
                    }
                }
            }
            .sheet(item: $unlockGroup) { group in
                UnlockSheet(group: group, sync: sync)
            }
            .sheet(item: $setupGroup) { group in
                SetupPickerView(group: group, sync: sync)
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(sync: sync) { showOnboarding = false }
            }
        }
    }
}

struct GroupRow: View {
    let group: RemoteGroup
    let policies: [RemotePolicy]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.name)
            let has = AppGroupStore.selection(for: group.id).map(EnforcementEngine.hasContent) ?? false
            let count = policies.filter { $0.groupId == group.id }.count
            Text(has ? "\(count) active polic\(count == 1 ? "y" : "ies")" : "⚠️ no apps selected — tap to choose")
                .font(.caption)
                .foregroundStyle(has ? Color.secondary : Color.orange)
        }
    }
}

struct GroupDetailView: View {
    let group: RemoteGroup
    @ObservedObject var sync: SyncCoordinator
    var autoOpenPicker = false
    @State private var selection = FamilyActivitySelection()
    @State private var pickerPresented = false

    @State private var unlockPresented = false

    var body: some View {
        Form {
            Section {
                if group.mode == "strict" {
                    Label("Strict mode — unlocks only through your ChatGPT coach", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        unlockPresented = true
                    } label: {
                        Label("Request time now", systemImage: "hourglass")
                    }
                }
            } footer: {
                Text(group.mode == "quota"
                     ? "\(group.quotaPerDay) self-serve unlocks of \(group.quotaMinutes) min per day, reason required."
                     : group.mode == "open" ? "Open mode — unlock freely." : "")
            }
            Section("Apps in this group") {
                Button("Choose apps (\(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories)") {
                    pickerPresented = true
                }
            }
            Section("Policies (managed from ChatGPT)") {
                let groupPolicies = sync.policies.filter { $0.groupId == group.id }
                if groupPolicies.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(groupPolicies) { p in
                    PolicyRow(policy: p)
                }
                let grants = sync.grants.filter {
                    $0.groupId == group.id && EnforcementEngine.activeGrant(for: group.id, in: [$0]) != nil
                }
                ForEach(grants) { g in
                    Label("Temporary access until \(ISO.date(g.expiresAt)?.formatted(date: .omitted, time: .shortened) ?? g.expiresAt)", systemImage: "clock")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(group.name)
        .sheet(isPresented: $unlockPresented) { UnlockSheet(group: group, sync: sync) }
        .familyActivityPicker(isPresented: $pickerPresented, selection: $selection)
        .onAppear {
            selection = AppGroupStore.selection(for: group.id) ?? FamilyActivitySelection()
            if autoOpenPicker && !EnforcementEngine.hasContent(selection) {
                pickerPresented = true
            }
        }
        .onChange(of: pickerPresented) { presented in
            guard !presented else { return }
            AppGroupStore.setSelection(selection, for: group.id)
            Task {
                try? await BackendClient.live.reportSelection(
                    groupId: group.id, hasSelection: EnforcementEngine.hasContent(selection))
                await sync.syncNow() // re-enforce with the new selection
            }
        }
    }
}

struct PolicyRow: View {
    let policy: RemotePolicy
    private static let dayNames = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    var body: some View {
        switch policy.kind {
        case "block":
            Label(policy.until.flatMap { u in
                ISO.date(u).map { "Blocked until \($0.formatted(date: .omitted, time: .shortened))" }
            } ?? "Blocked until you (or ChatGPT) unblock it", systemImage: "hand.raised.fill")
        case "schedule":
            let days = (policy.daysOfWeek ?? []).map { Self.dayNames[$0] }.joined(separator: " ")
            Label("\(policy.startTime ?? "?")–\(policy.endTime ?? "?") \(days)", systemImage: "calendar")
        case "limit":
            Label("\(policy.minutesPerDay ?? 0) min/day", systemImage: "timer")
        default:
            Text(policy.kind)
        }
    }
}
