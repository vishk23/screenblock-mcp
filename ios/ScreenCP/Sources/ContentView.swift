import SwiftUI
import FamilyControls

struct ContentView: View {
    @StateObject private var sync = SyncCoordinator()
    @State private var authStatus = AuthorizationCenter.shared.authorizationStatus
    @State private var unlockGroup: RemoteGroup?
    @State private var setupGroup: RemoteGroup?
    @State private var creatingStarters = false
    @State private var showOnboarding = !AppGroupStore.suite.bool(forKey: "onboarded")
    @StateObject private var today = TodayModel()
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
                if let d = today.day { TodayView(day: d) }
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
                            GroupRow(group: group, policies: sync.policies, grants: sync.grants)
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
                    NavigationLink("Developer tools") { SpikeView() }
                }
            }
            .navigationTitle(Brand.name)
            .refreshable { await sync.syncNow(); await today.load() }
            .task { await sync.syncNow(); await today.load() }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await sync.syncNow()
                        await today.load()
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
    let grants: [RemoteGrant]

    private var modeIcon: String {
        switch group.mode {
        case "strict": return "lock.fill"
        case "open": return "lock.open"
        default: return "circle.grid.2x1"
        }
    }

    private var summary: (text: String, color: Color) {
        let has = AppGroupStore.selection(for: group.id).map(EnforcementEngine.hasContent) ?? false
        guard has else { return ("No apps selected — tap to choose", .orange) }

        if let grant = EnforcementEngine.activeGrant(for: group.id, in: grants),
           let until = ISO.date(grant.expiresAt) {
            return ("Open until \(until.formatted(date: .omitted, time: .shortened))", .green)
        }

        var parts: [String] = []
        let mine = policies.filter { $0.groupId == group.id }
        if mine.contains(where: { $0.kind == "block" }) { parts.append("Blocked") }
        for p in mine where p.kind == "schedule" {
            parts.append("\(p.startTime ?? "?")–\(p.endTime ?? "?")")
        }
        for p in mine where p.kind == "limit" {
            parts.append("\(p.minutesPerDay ?? 0) min/day")
        }
        switch group.mode {
        case "quota":
            let used = EnforcementEngine.quotaUsedToday(
                groupId: group.id, grants: grants + AppGroupStore.pendingLocalGrants)
            parts.append("\(max(0, group.quotaPerDay - used)) of \(group.quotaPerDay) unlocks left")
        case "strict":
            parts.append("strict")
        default: break
        }
        return (parts.isEmpty ? "No rules yet — set them from ChatGPT" : parts.joined(separator: " · "), .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(group.name)
                Image(systemName: modeIcon).font(.caption2).foregroundStyle(.secondary)
            }
            let s = summary
            Text(s.text).font(.caption).foregroundStyle(s.color)
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
                    if group.mode == "quota" {
                        let used = EnforcementEngine.quotaUsedToday(
                            groupId: group.id, grants: sync.grants + AppGroupStore.pendingLocalGrants)
                        LabeledContent("Unlocks left today",
                                       value: "\(max(0, group.quotaPerDay - used)) of \(group.quotaPerDay)")
                    }
                    Button {
                        unlockPresented = true
                    } label: {
                        Label("Request time now", systemImage: "hourglass")
                    }
                }
            } footer: {
                Text(group.mode == "quota"
                     ? "Each unlock lasts \(group.quotaMinutes) min, reason required. Change the rules by telling ChatGPT."
                     : group.mode == "open" ? "Open mode — unlock freely. Tell ChatGPT to make it stricter."
                     : "Only your ChatGPT coach can unlock this group.")
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
