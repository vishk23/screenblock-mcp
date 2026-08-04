import SwiftUI
import FamilyControls
import UserNotifications

/// First-run guided setup: permission → groups → apps → modes → connect coach.
struct OnboardingView: View {
    @ObservedObject var sync: SyncCoordinator
    var onDone: () -> Void

    @State private var page = 0
    @State private var authStatus = AuthorizationCenter.shared.authorizationStatus
    @State private var creatingStarters = false
    @State private var pickingGroup: RemoteGroup?
    @State private var customName = ""

    var body: some View {
        TabView(selection: $page) {
            welcome.tag(0)
            permission.tag(1)
            groups.tag(2)
            perApp.tag(3)
            modes.tag(4)
            connect.tag(5)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .sheet(item: $pickingGroup) { group in
            SetupPickerView(group: group, sync: sync)
        }
    }

    private func pageBody(icon: String, _ title: String, _ text: String,
                          @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: icon).font(.system(size: 56)).foregroundStyle(.tint)
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            content()
            Spacer()
            Spacer()
        }
        .padding()
    }

    private var welcome: some View {
        pageBody(icon: "brain.head.profile", "Your coach controls the locks",
                 "\(Brand.name) blocks distracting apps on this iPhone — and ChatGPT is the control room. You talk; your phone obeys. This setup takes about two minutes.") {
            Button("Get started") { withAnimation { page = 1 } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var permission: some View {
        pageBody(icon: "hourglass", "Allow Screen Time access",
                 "Apple requires your explicit permission before any app can shield another. Everything stays on this phone — which apps you pick is invisible even to our own server.") {
            if authStatus == .approved {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Continue") { withAnimation { page = 2 } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Allow Screen Time Access") {
                    Task {
                        try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                        authStatus = AuthorizationCenter.shared.authorizationStatus
                        if authStatus == .approved { withAnimation { page = 2 } }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var groups: some View {
        pageBody(icon: "square.grid.2x2", "Build your groups",
                 "Groups are what ChatGPT controls: block Social, limit Games, 15 minutes of Entertainment. These three are just common starting points — add your own below, or rename/add later by telling ChatGPT. Tap each group and pick its apps.") {
            VStack(spacing: 12) {
                if sync.groups.isEmpty {
                    Button(creatingStarters ? "Creating…" : "Create Social, Games & Entertainment") {
                        creatingStarters = true
                        Task {
                            for name in ["Social", "Games", "Entertainment"] {
                                try? await BackendClient.live.createGroup(name: name)
                            }
                            await sync.syncNow()
                            creatingStarters = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(creatingStarters)
                } else {
                    ForEach(sync.groups) { group in
                        let done = AppGroupStore.selection(for: group.id).map(EnforcementEngine.hasContent) ?? false
                        Button {
                            pickingGroup = group
                        } label: {
                            HStack {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(done ? .green : .secondary)
                                Text(group.name)
                                Spacer()
                                Text(done ? "apps picked" : "pick apps").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        TextField("Add your own (e.g. Reddit)", text: $customName)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let name = customName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            customName = ""
                            Task {
                                try? await BackendClient.live.createGroup(name: name)
                                await sync.syncNow()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Continue") { withAnimation { page = 3 } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!sync.groups.contains {
                            AppGroupStore.selection(for: $0.id).map(EnforcementEngine.hasContent) ?? false
                        })
                }
            }
            .padding(.horizontal)
        }
    }

    private static let hotApps = ["TikTok", "Instagram", "X", "YouTube", "Snapchat"]
    @State private var creatingHot: String?

    /// The page the group/matrix confusion kept pointing at: hot apps get their
    /// OWN group so "give me 10 minutes of TikTok" unlocks only TikTok.
    private var perApp: some View {
        pageBody(icon: "scope", "Give your worst apps their own group",
                 "Grants work on whole groups. If TikTok lives only inside Social, \u{201C}10 minutes of TikTok\u{201D} opens ALL of Social. Give a tempting app its own group and requests become surgical — it can stay in Social too; the single-app group wins.") {
            VStack(spacing: 10) {
                ForEach(Self.hotApps, id: \.self) { name in
                    let existing = sync.groups.first { $0.name.lowercased() == name.lowercased() }
                    let done = existing.flatMap { g in
                        AppGroupStore.selection(for: g.id).map(EnforcementEngine.hasContent)
                    } ?? false
                    Button {
                        if let existing {
                            pickingGroup = existing
                        } else {
                            creatingHot = name
                            Task {
                                try? await BackendClient.live.createGroup(name: name)
                                await sync.syncNow()
                                creatingHot = nil
                                pickingGroup = sync.groups.first { $0.name.lowercased() == name.lowercased() }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: done ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(done ? .green : .secondary)
                            Text(name)
                            Spacer()
                            if creatingHot == name { ProgressView() }
                        }
                        .padding(.horizontal)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Optional — skip if none of these tempt you.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Continue") { withAnimation { page = 4 } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
    }

    private var modes: some View {
        pageBody(icon: "lock.shield", "Choose your strictness — later, in chat",
                 "Every group has an unlock mode you set by talking to ChatGPT:\n\n“Make Social strict” — chat is the only way out.\n“Give Games 2 unlocks of 10 minutes a day” — self-serve with a reason, rationed.\n“Keep News open” — unlock freely.\n\nYou pick your prison's strictness in advance, not in the moment of temptation.") {
            Button("Continue") { withAnimation { page = 5 } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var connect: some View {
        pageBody(icon: "bubble.left.and.text.bubble.right", "Connect your coach",
                 "In ChatGPT: Settings → Apps & Connectors → enable Developer mode → Create, and paste your \(Brand.name) connector URL (you have it from setup). Then just talk:\n\n“Block Social till 5.”\n“Give me 15 minutes of Games.”\n“How did I do today?”") {
            Button("Done — start blocking") {
                AppGroupStore.suite.set(true, forKey: "onboarded")
                // Deferred from launch: notifications power the "tap to apply"
                // and "request time" flows, so ask now that there's context.
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                onDone()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
