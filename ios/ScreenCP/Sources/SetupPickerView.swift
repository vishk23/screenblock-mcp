import SwiftUI
import FamilyControls

/// Picker-only setup screen (onboarding + "choose apps" nudges).
/// Deliberately NOT GroupDetailView: no unlock button, no policies —
/// setup time is for picking apps, nothing else.
struct SetupPickerView: View {
    let group: RemoteGroup
    @ObservedObject var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selection = FamilyActivitySelection()
    @State private var pickerPresented = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.grid.2x2").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Pick apps for \(group.name)").font(.title2.bold())
            Text("Tap individual apps rather than whole categories — that's what lets ChatGPT grant single apps later.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Choose apps (\(selection.applicationTokens.count) apps, \(selection.categoryTokens.count) categories)") {
                pickerPresented = true
            }
            .buttonStyle(.borderedProminent)
            Button("Done") { dismiss() }
            Spacer()
        }
        .familyActivityPicker(isPresented: $pickerPresented, selection: $selection)
        .onAppear {
            selection = AppGroupStore.selection(for: group.id) ?? FamilyActivitySelection()
            if !EnforcementEngine.hasContent(selection) { pickerPresented = true }
        }
        .onChange(of: pickerPresented) { presented in
            guard !presented else { return }
            AppGroupStore.setSelection(selection, for: group.id)
            Task {
                try? await BackendClient.live.reportSelection(
                    groupId: group.id, hasSelection: EnforcementEngine.hasContent(selection))
                await sync.syncNow()
            }
        }
    }
}
