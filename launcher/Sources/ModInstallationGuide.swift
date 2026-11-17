import SwiftUI

struct ModInstallationGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mod Installation Guide").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    guideSection("Start with Add Mod", text: "Quit the game, then use Add Mod to choose downloaded ZIPs or extracted mod folders, or drag them onto the launcher. Review detected requirements, issues and files before clicking Install. Cancel leaves your game unchanged. Click Play after installation and script compilation finish.")
                    guideSection("Resolve import issues", text: "Missing requirements, unsupported components and conflicting files block installation. Existing files are not overwritten. Follow the mod author's removal instructions before replacing an older version. You can select a required gameplay mod in the same import.")
                    guideSection("Optional mods", text: "Open Optional Mods to choose Equipment-EX or Cyberware-EX. Both are optional. Existing installations stay in place. Download Virtual Atelier from its official page and import it, then add a separate Atelier store mod.")
                    guideSection("Included frameworks on game 2.5", text: "Install includes the native macOS RED4ext, ArchiveXL, TweakXL, scoped Codeware support, Input Loader, Mod Settings and redscript compiler. Download gameplay mods separately and import them with Add Mod. Compatible mods add their controls to the game's Mod Settings menu; Input Loader supplies their custom key bindings.")
                    guideSection("Original Lua mods in 2.0", text: "Add Mod accepts the reviewed Native Settings 1.97, Vehicle Call Cost, ITP 2.0.1, and Mansion 2.0 with Native Interactions Framework 1.1.5. Select dependencies together. Extract the large ITP download and select its complete folder. ITP requires Native Settings, but not Mansion. Original ITP scripts are kept unchanged; newer or edited Lua versions need a compatibility update.")
                    guideSection("Settings and camera", text: "Native Settings uses the separate MODS menu, not MOD SETTINGS or MOD.IO. Adjust ITP distance and height there, or use F1 → Exploration → Camera to toggle third person. Weapon drawing uses first person for aiming. F1 → Lua mods shows module state and errors; if camera recovery is unverified after an ITP error, quit and relaunch the game before using it again.")
                    guideSection("Named profiles", text: "With the game closed, use Profiles to save and apply named managed Lua mod selections or restore the previous selection. Other mods and saves stay in place. Mod settings are shared, not copied between profiles. Required dependencies cannot be removed while selected mods still need them.")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where files go").font(.headline)
                        Text("Paths are relative to your selected Cyberpunk 2077 folder. Add Mod handles standard ZIP layouts and supported archive conversion. Use Mac-compatible files for manual installation; moving a Windows archive into a Mac folder does not convert it.")
                            .font(.callout).foregroundColor(.secondary)
                        pathRow("archive/Mac/mod", detail: "Compatible archives; verified VA / Equipment .archive.xl files stay beside them")
                        pathRow("r6/scripts", detail: "Redscript mod folders and .reds files")
                        pathRow("r6/tweaks", detail: "TweakXL data files")
                        pathRow("r6/input", detail: "Input Loader XML bindings")
                        pathRow("red4ext/nightcity-native20", detail: "Managed Lua packages, saved profile revisions and separate mod settings")
                    }
                    guideSection("Check compatibility", text: "The preview detects some requirements, but cannot certify arbitrary mods or infer every required version. Windows .dll plugins and unreviewed CET Lua packages are unsupported. Keep NightCity's managed native frameworks; other Codeware-dependent mods still need compatibility testing.")
                    guideSection("If a mod does not load", text: "Read the launcher’s status message and check the mod’s required version. Use the trash button to remove mods installed through Add Mod. Back up your saves before changing gameplay mods. Export Diagnostics creates a local support ZIP when you need help.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Available offline").font(.caption).foregroundColor(.secondary)
                Link("Full guide ↗", destination: URL(string: "https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/MOD-INSTALLATION.md")!)
                    .font(.caption)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 550, height: 540)
    }

    private func guideSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundColor(.secondary)
        }
    }

    private func pathRow(_ path: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
    }
}
