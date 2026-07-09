import SwiftUI
import FamilyControls
import ManagedSettings

/// Spike 1 (plan M0): prove entitlement -> authorization -> picker -> shield.
struct SpikeView: View {
    @State private var authStatus = "unknown"
    @State private var selection = FamilyActivitySelection()
    @State private var pickerPresented = false
    @State private var shieldOn = false
    @State private var lastError = ""

    private let store = ManagedSettingsStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Authorization") {
                    Text("Status: \(authStatus)")
                    Button("Request Screen Time Authorization") {
                        Task {
                            do {
                                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                                authStatus = "approved"
                            } catch {
                                authStatus = "denied/failed"
                                lastError = String(describing: error)
                            }
                        }
                    }
                }
                Section("2. Pick apps to control") {
                    Button("Choose Apps (\(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories)") {
                        pickerPresented = true
                    }
                }
                Section("3. Shield") {
                    Toggle("Shield selected apps NOW", isOn: $shieldOn)
                        .onChange(of: shieldOn) { on in
                            if on {
                                store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
                                store.shield.applicationCategories = selection.categoryTokens.isEmpty
                                    ? nil
                                    : .specific(selection.categoryTokens)
                            } else {
                                store.shield.applications = nil
                                store.shield.applicationCategories = nil
                            }
                        }
                }
                if !lastError.isEmpty {
                    Section("Last error") { Text(lastError).font(.footnote) }
                }
            }
            .navigationTitle("ScreenCP Spike")
            .familyActivityPicker(isPresented: $pickerPresented, selection: $selection)
            .onAppear {
                authStatus = String(describing: AuthorizationCenter.shared.authorizationStatus)
            }
        }
    }
}
