import SwiftUI

struct OptionalModsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var availableSelection: Set<String> {
        Set(model.optionalMods.filter {
            selected.contains($0.id) && model.optionalModStatus($0) == nil
        }.map(\.id))
    }

    private var changesDisabled: Bool { model.busy || model.gameIsRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Optional Mods").font(.title2.bold())
                Text("Choose the mods you want. Nothing is installed automatically.")
                    .foregroundColor(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Included installers · game 2.5").font(.headline)
                        ForEach(model.optionalMods) { mod in modRow(mod) }
                        if let error = model.optionalModsError {
                            Text(error).font(.callout).foregroundColor(.orange)
                        }
                        if model.gameIsRunning {
                            Text("Quit Cyberpunk 2077 before installing mods.")
                                .font(.callout).foregroundColor(.secondary)
                        } else if !model.installed {
                            Text("Install NightCity Console in your game folder first.")
                                .font(.callout).foregroundColor(.secondary)
                        } else if model.gameVersion != "2.5.0" {
                            Text("These optional installers require Cyberpunk 2077 2.5.")
                                .font(.callout).foregroundColor(.secondary)
                        }
                        Button(availableSelection.isEmpty ? "Install Selected" : "Install Selected (\(availableSelection.count))") {
                            let ids = availableSelection
                            selected.removeAll()
                            model.installOptionalMods(ids: ids)
                        }
                        .disabled(availableSelection.isEmpty || !model.canInstallOptionalMods || changesDisabled)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Virtual Atelier").font(.headline)
                        Text("Download Virtual Atelier from its official page, then import the ZIP or extracted mod folder. Tested with version 1.6.0.")
                            .font(.callout).foregroundColor(.secondary)
                        Text("Install a separate Atelier store mod to see shops and items. Virtual Atelier alone does not include stores.")
                            .font(.callout)
                        Link("Tested store: PUBLICNET 1.2.1 (now A.G.I.S.) ↗", destination: URL(string: "https://www.nexusmods.com/cyberpunk2077/mods/10909")!)
                            .font(.caption)
                        HStack {
                            Link("Download Virtual Atelier ↗", destination: URL(string: "https://www.nexusmods.com/cyberpunk2077/mods/2987")!)
                            Spacer()
                            Button("Import VA…") { importAtelier() }
                                .disabled(!model.installed || changesDisabled || model.gameVersion != "2.5.0")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.busy {
                ProgressView(value: min(max(model.progress, 0), 1))
                Text(model.busyDetail.isEmpty ? "Installing mods…" : model.busyDetail)
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
            } else if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundColor(.secondary).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 550, height: 540)
        .onAppear { model.refreshMods() }
    }

    private func modRow(_ mod: OptionalMod) -> some View {
        let installedStatus = model.optionalModStatus(mod)
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { installedStatus == nil && selected.contains(mod.id) },
                set: { value in
                    if value { selected.insert(mod.id) } else { selected.remove(mod.id) }
                })) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(mod.name).font(.callout.bold())
                        Text(mod.version).font(.caption).foregroundColor(.secondary)
                    }
                    if let status = installedStatus {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(mod.name.localizedCaseInsensitiveContains("Cyberware")
                             ? "Expand cyberware slots and operating system options."
                             : "Manage clothing slots and saved outfits.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(installedStatus != nil || changesDisabled || !model.canInstallOptionalMods)
        }
        .padding(.vertical, 3)
    }

    private func importAtelier() {
        guard model.installed, !changesDisabled, model.gameVersion == "2.5.0" else { return }
        ModFilePicker.choose(message: "Select the Virtual Atelier ZIP or extracted mod folder", multiple: false) { urls in
            guard !model.busy, !model.gameIsRunning else { return }
            model.importVirtualAtelier(from: urls)
        }
    }
}
