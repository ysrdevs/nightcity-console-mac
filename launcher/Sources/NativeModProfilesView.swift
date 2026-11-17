import SwiftUI

struct NativeModProfilesView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Native mod profiles").font(.title2)
            Text("Profiles switch the imported native mods listed in the launcher. Other mods stay installed. Mod settings are shared between profiles; save files and Creator weapons are kept.")
                .font(.callout).foregroundColor(.secondary)
            HStack {
                TextField("New profile name", text: $name)
                Button("Save current") { model.saveNativeProfile(name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy || model.gameIsRunning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.nativeProfiles.isEmpty { Text("No saved profiles yet.").foregroundColor(.secondary) }
                    ForEach(model.nativeProfiles) { profile in
                        HStack {
                            Text(profile.name); Spacer()
                            if model.nativeSelectionRevision == profile.revision { Text("Selected").font(.caption).foregroundColor(.secondary) }
                            Button("Apply") { model.applyNativeProfile(profile) }.disabled(model.busy || model.gameIsRunning || model.nativeSelectionRevision == profile.revision)
                            Button { model.deleteNativeProfile(profile) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).disabled(model.busy || model.gameIsRunning).help("Delete this saved profile; keep the current mods")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.status).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            if model.busy { ProgressView(model.busyDetail) }
            HStack {
                Button("Restore previous selection") { model.restoreNativeMods() }.disabled(!model.nativeCanRestore || model.busy || model.gameIsRunning)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
        }.padding(24).frame(width: 590, height: 420).interactiveDismissDisabled(model.busy)
    }
}
