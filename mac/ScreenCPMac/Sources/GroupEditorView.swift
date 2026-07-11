import SwiftUI

/// Standalone window: map installed Mac apps into a ScreenCP group.
/// The Mac analog of the iOS FamilyActivityPicker — except macOS lets us
/// build it ourselves, with search and no opaque tokens.
struct GroupEditorView: View {
    let groupId: String
    @ObservedObject private var sync = MacSync.shared
    @State private var apps: [InstalledApp] = []
    @State private var query = ""

    private var group: RemoteGroup? { sync.groups.first { $0.id == groupId } }
    private var filtered: [InstalledApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apps in \u{201C}\(group?.name ?? "group")\u{201D} on this Mac")
                .font(.headline)
            Text("Checked apps follow this group's rules here — blocks, schedules, grants. The iPhone side is picked separately in the iOS app.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search apps…", text: $query)
                .textFieldStyle(.roundedBorder)
            List(filtered) { app in
                Toggle(app.name, isOn: Binding(
                    get: { sync.selections[groupId, default: []].contains(app.id) },
                    set: { on in
                        var sel = sync.selections[groupId, default: []]
                        if on { sel.insert(app.id) } else { sel.remove(app.id) }
                        sync.selections[groupId] = sel
                    }
                ))
            }
            HStack {
                Text("\(sync.selections[groupId, default: []].count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    Task { await sync.syncNow() } // re-enforce with the new mapping
                    NSApplication.shared.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420, height: 520)
        .onAppear { apps = InstalledApp.scan() }
    }
}
