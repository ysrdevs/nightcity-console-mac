import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum GameStore {
    case steam, gog, unknown

    var name: String {
        switch self {
        case .steam: return "Steam"
        case .gog: return "GOG"
        case .unknown: return "Unknown"
        }
    }
}

enum Const {
    static let appVersion = "1.5.0"
    static let supportedGameVersion = "2.3.1"
    static let steamGame = "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
    static let gogGame = "/Applications/Cyberpunk 2077"
    // Files copied from the app's Resources into <game>/red4ext/ on install. config.ini is REQUIRED - RED4ext
    // reads [plugins] enabled=true from it; without it no plugins load. cyberpunk2077_addresses.json is its
    // AddressLib. (TweakXL + ArchiveXL ship as vendored plugin DIRS - deployed separately, see install().)
    static let payload = ["red4ext_hooks.js", "red4ext_hooks_gog.js", "FridaGadget.config", "RED4ext.dylib",
                          "FridaGadget.dylib", "libcyberconsole_overlay.dylib", "cet_catalog.tsv",
                          "config.ini", "cyberpunk2077_addresses.json"]
    // The names file is user data once they start creating, so it is seeded only when absent (never overwritten).
    static let cmnPayload: [(res: String, dest: String, seedOnly: Bool)] = [
        ("cybermodman_names.json",  "red4ext/cybermodman_names.json",        true),
    ]
    static let repo = "ysrdevs/nightcity-console-mac"
    static let commandsURL = "https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/COMMANDS.md"
    static let supportURL = "https://ko-fi.com/ysrdevs"
}

final class Model: ObservableObject {
    @Published var gamePath: String
    @Published var status: String = ""
    @Published var installed: Bool = false
    @Published var gameVersion: String? = nil
    @Published var updateText: String? = nil      // set when a newer release is found on GitHub
    @Published var updateURL: String? = nil
    @Published var updateTag: String? = nil        // the new release tag (for the "What's new in ..." title)
    @Published var updateBody: String? = nil       // the release notes / changelog (GitHub release body)
    @Published var needsGameAccess: Bool = false  // set when macOS blocks writing to or re-signing the game

    private let defaults = UserDefaults.standard

    // External libraries may need Full Disk Access. Apps under /Applications may instead need
    // App Management permission before another app can update or re-sign them.
    var gameOnExternalDrive: Bool { gamePath.hasPrefix("/Volumes/") }
    func looksLikePermissionError(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("not permitted") || l.contains("permission denied") || l.contains("operation not permitted")
    }
    func openGameAccessSettings() {
        let pane = gameOnExternalDrive ? "Privacy_AllFiles" : "Privacy_AppBundles"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    init() {
        let fm = FileManager.default
        let saved = defaults.string(forKey: "gamePath")
        if let saved, fm.fileExists(atPath: "\(saved)/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077") {
            gamePath = saved
        } else if fm.fileExists(atPath: "\(Const.gogGame)/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077") {
            gamePath = Const.gogGame
        } else {
            gamePath = Const.steamGame
        }
        refresh()
        checkForUpdates()
    }

    var binaryPath: String { "\(gamePath)/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" }
    var red4Dir: String { "\(gamePath)/red4ext" }
    var gameFound: Bool { FileManager.default.fileExists(atPath: binaryPath) }
    var gameStore: GameStore {
        let fm = FileManager.default
        if readBundleIdentifier() == "com.cdprojektred.cyberpunk.gog" ||
            fm.fileExists(atPath: "\(gamePath)/Cyberpunk2077.app/Contents/Frameworks/libGameServicesGOG.dylib") {
            return .gog
        }
        if gamePath.lowercased().contains("/steamapps/") { return .steam }
        return .unknown
    }
    var expectedHook: String? {
        switch gameStore {
        case .gog: return "red4ext_hooks_gog.js"
        case .steam: return "red4ext_hooks.js"
        case .unknown: return nil
        }
    }

    // GOG's Frida engine is standalone. The upstream RED4ext loader/address library and plugins
    // still target Steam; do not load or deploy them into the GOG process.
    var runtimePayload: [String] {
        gameStore == .gog
            ? Const.payload.filter { !["RED4ext.dylib", "config.ini", "cyberpunk2077_addresses.json"].contains($0) }
            : Const.payload
    }
    var injectDylibs: [String] {
        gameStore == .gog
            ? ["FridaGadget.dylib", "libcyberconsole_overlay.dylib"]
            : ["RED4ext.dylib", "FridaGadget.dylib", "libcyberconsole_overlay.dylib"]
    }
    func fullyInstalled() -> Bool {
        let fm = FileManager.default
        let core = runtimePayload.allSatisfy { fm.fileExists(atPath: "\(red4Dir)/\($0)") }
        if gameStore == .gog { return core && fridaConfigMatchesStore() }
        let tweakXL = fm.fileExists(atPath: "\(gamePath)/red4ext/plugins/TweakXL/TweakXL.dylib")
        let archiveXL = fm.fileExists(atPath: "\(gamePath)/red4ext/plugins/ArchiveXL/ArchiveXL.dylib")
        // scc (the redscript compiler) is required only when the app bundle actually ships it, so old
        // installs self-heal via play()'s install() call without bricking dev builds that lack it.
        let scc = sccResourcePath() == nil || fm.fileExists(atPath: sccGamePath)
        return core && tweakXL && archiveXL && scc && fridaConfigMatchesStore()
    }

    // MARK: - redscript (scc) integration

    // The bundled redscript compiler (jac3km4/redscript, arm64). Deployed into the game's engine/tools/
    // (the layout scc's cache/backup logic expects, same as Windows) and run from there.
    var sccGameDir: String { "\(gamePath)/engine/tools" }
    var sccGamePath: String { "\(sccGameDir)/scc" }
    func sccResourcePath() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let d = res.appendingPathComponent("scc")
        return FileManager.default.isExecutableFile(atPath: d.appendingPathComponent("scc").path) ? d : nil
    }

    // True when any redscript source is deployed (script mods put .reds under r6/scripts/<Mod>/).
    func hasScripts() -> Bool {
        guard let e = FileManager.default.enumerator(atPath: "\(gamePath)/r6/scripts") else { return false }
        for case let f as String in e where f.hasSuffix(".reds") { return true }
        return false
    }

    // Deploy scc + libscc_lib.dylib from the app bundle into <game>/engine/tools/.
    private func deployScc() throws {
        guard let src = sccResourcePath() else { return }   // not bundled (dev build) - skip quietly
        let fm = FileManager.default
        try fm.createDirectory(atPath: sccGameDir, withIntermediateDirectories: true)
        for f in ["scc", "libscc_lib.dylib"] {
            let s = src.appendingPathComponent(f)
            guard fm.fileExists(atPath: s.path) else { continue }
            let d = "\(sccGameDir)/\(f)"
            if fm.fileExists(atPath: d) { try fm.removeItem(atPath: d) }
            try fm.copyItem(at: s, to: URL(fileURLWithPath: d))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d)
        }
        stripQuarantine(sccGameDir)
    }

    // Compile all deployed .reds (r6/scripts) into the game's script cache (r6/cache/final.redscripts)
    // with the bundled redscript compiler. scc backs the vanilla cache up to final.redscripts.bk on first
    // run and only overwrites the cache when compilation SUCCEEDS, so a broken script mod fail-opens to
    // the previous good cache. A full compile takes ~0.3s. Returns nil on success, else a short error.
    // MUST be called off the main thread.
    private func compileScripts() -> String? {
        let scriptsDir = "\(gamePath)/r6/scripts"
        // Removing the last script mod may leave the dir empty/missing; compiling an empty dir is how
        // the cache gets restored to base-only, so make sure the dir exists rather than skipping.
        try? FileManager.default.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sccGamePath)
        p.arguments = ["-compile", scriptsDir]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "could not run scc: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0, out.contains("Output successfully saved") else {
            let err = out.split(whereSeparator: \.isNewline).first { $0.contains("ERROR") }
            return err.map(String.init) ?? lastLine(out)
        }
        return nil
    }

    func fridaConfigMatchesStore() -> Bool {
        guard let expectedHook,
              let data = FileManager.default.contents(atPath: "\(red4Dir)/FridaGadget.config"),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let interaction = root["interaction"] as? [String: Any],
              let path = interaction["path"] as? String else { return false }
        return path == "./\(expectedHook)" &&
            interaction["type"] as? String == "script" &&
            interaction["on_load"] as? String == "resume"
    }

    func writeFridaConfig() throws {
        guard let expectedHook else { throw CocoaError(.fileReadUnsupportedScheme) }
        let config: [String: Any] = [
            "interaction": [
                "type": "script",
                "path": "./\(expectedHook)",
                "on_load": "resume",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "\(red4Dir)/FridaGadget.config"), options: .atomic)
    }

    func setGamePath(_ p: String) {
        gamePath = p
        defaults.set(p, forKey: "gamePath")
        refresh()
    }

    func refresh() {
        gameVersion = readGameVersion()
        installed = fullyInstalled()
        refreshMods()
        if !gameFound {
            status = "Cyberpunk 2077 not found here - click Browse to locate it."
        } else {
            let v = gameVersion.map { " (v\($0))" } ?? ""
            let store = gameStore == .unknown ? "" : " · \(gameStore.name)"
            status = "Game found\(v)\(store)" + (installed ? " · NightCity Console installed" : " · not installed yet")
        }
    }

    // Best-effort GitHub Releases check. Silent on any failure (offline, rate limit, parse error).
    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/\(Const.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("nightcity-console-update-check", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  Model.isNewer(tag, than: Const.appVersion) else { return }
            var dl = (obj["html_url"] as? String) ?? "https://github.com/\(Const.repo)/releases/latest"
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets where (a["name"] as? String)?.lowercased().hasSuffix(".dmg") == true {
                    if let u = a["browser_download_url"] as? String { dl = u; break }
                }
            }
            // Release notes (markdown) ride along in the same response - no extra request.
            let body = (obj["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.updateText = "Update available: \(tag). Download the new version and replace the app."
                self.updateURL = dl
                self.updateTag = tag
                self.updateBody = (body?.isEmpty == false) ? body : nil
            }
        }.resume()
    }

    // Compare dotted version tags (leading v/V tolerated). Returns true if `tag` > `current`.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func readGameVersion() -> String? {
        let plist = "\(gamePath)/Cyberpunk2077.app/Contents/Info.plist"
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    func readBundleIdentifier() -> String? {
        let plist = "\(gamePath)/Cyberpunk2077.app/Contents/Info.plist"
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        return d["CFBundleIdentifier"] as? String
    }

    func install() {
        guard gameFound else { status = "Game not found."; return }
        guard gameStore != .unknown else { status = "Unsupported game build. Select a Steam or GOG Cyberpunk 2077 folder."; return }
        guard let res = Bundle.main.resourceURL else { status = "Bundle resources missing."; return }
        needsGameAccess = false
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: red4Dir, withIntermediateDirectories: true)
            for f in runtimePayload {
                let src = res.appendingPathComponent(f)
                guard fm.fileExists(atPath: src.path) else { status = "Missing bundled file: \(f)"; return }
                let dst = URL(fileURLWithPath: "\(red4Dir)/\(f)")
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            // The app carries both command engines. Frida must load the one matching the detected store.
            try writeFridaConfig()
            if gameStore == .gog {
                stripQuarantine(red4Dir)
                guard ensureGameEntitlements() else { return }
                refresh()
                return
            }
            // CyberModMan creator payload (seed names file)
            for item in Const.cmnPayload {
                let src = res.appendingPathComponent(item.res)
                guard fm.fileExists(atPath: src.path) else { status = "Missing bundled file: \(item.res)"; return }
                let dstPath = "\(gamePath)/\(item.dest)"
                let dst = URL(fileURLWithPath: dstPath)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if item.seedOnly && fm.fileExists(atPath: dstPath) { continue }   // don't clobber user creations
                if fm.fileExists(atPath: dstPath) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            // Vendored RED4ext plugins (TweakXL + ArchiveXL) - each is a self-contained folder (plugin dylib +
            // its Homebrew spdlog/fmt/yaml-cpp deps rebound to @loader_path). Deploy the whole folder so the
            // plugins load on a Mac with no Homebrew (the reason mods failed on a fresh machine).
            let pluginsSrc = res.appendingPathComponent("plugins")
            if let names = try? fm.contentsOfDirectory(atPath: pluginsSrc.path) {
                for name in names where !name.hasPrefix(".") {
                    let src = pluginsSrc.appendingPathComponent(name)
                    let dstPath = "\(gamePath)/red4ext/plugins/\(name)"
                    try fm.createDirectory(atPath: "\(gamePath)/red4ext/plugins", withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dstPath) { try fm.removeItem(atPath: dstPath) }
                    try fm.copyItem(at: src, to: URL(fileURLWithPath: dstPath))
                }
            }
            try deployScc()            // redscript compiler -> <game>/engine/tools/ (script-mod support)
            stripQuarantine(red4Dir)   // files we just wrote (incl. plugins/*) -> make dyld load them
            guard ensureGameEntitlements() else { return }   // status set on failure
            status = "Installed - click Play."
            refresh()
        } catch {
            let msg = error.localizedDescription
            if looksLikePermissionError(msg) || gameOnExternalDrive {
                needsGameAccess = true
                status = "macOS blocked changes to the game. Open Privacy settings below, enable NightCity Console, then click Install again."
            } else {
                status = "Install failed: \(msg)"
            }
        }
    }

    // Stock Cyberpunk ships signed with only allow-dyld-environment-variables + disable-library-validation.
    // Frida is a JIT: it writes machine code at runtime. Without allow-jit / allow-unsigned-executable-memory
    // the OS code-signing monitor SIGKILLs the game (CODESIGNING, Invalid Page) the instant Frida generates
    // code. We re-sign the game binary ad-hoc with those entitlements. No SIP changes. Fully reversible:
    // Steam Verify or GOG Verify/Repair restores the original signature (and a later Play re-applies this).
    @discardableResult
    func ensureGameEntitlements() -> Bool {
        if gameHasJITEntitlement() { return true }   // already done; skip the (re)sign
        let ents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
        <key>com.apple.security.cs.allow-jit</key><true/>
        <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
        <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
        <key>com.apple.security.cs.disable-library-validation</key><true/>
        </dict></plist>
        """
        let plistPath = NSTemporaryDirectory() + "nightcity-entitlements.plist"
        do { try ents.write(toFile: plistPath, atomically: true, encoding: .utf8) }
        catch { status = "Could not prepare entitlements: \(error.localizedDescription)"; return false }
        // Non-APFS drives (exFAT game libraries) create "._" AppleDouble sidecars that codesign treats as
        // unsigned nested code and refuses to sign. Strip them from the .app bundle before re-signing.
        stripAppleDoubles("\(gamePath)/Cyberpunk2077.app")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-f", "-s", "-", "--entitlements", plistPath, binaryPath]
        let err = Pipe(); p.standardError = err
        do { try p.run(); p.waitUntilExit() }
        catch { status = "Could not run codesign: \(error.localizedDescription)"; return false }
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if looksLikePermissionError(msg) || gameOnExternalDrive {
                needsGameAccess = true
                status = "macOS blocked re-signing the game. Open Privacy settings below, enable NightCity Console, then click Install again."
            } else {
                status = "Re-signing the game failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return false
        }
        return true
    }

    // True if the game binary already carries the JIT entitlement (so we can skip re-signing).
    func gameHasJITEntitlement() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "--entitlements", ":-", binaryPath]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.contains("allow-jit")
    }

    // Delete "._" AppleDouble sidecar files in a path (created on exFAT/non-APFS volumes; they break codesign).
    func stripAppleDoubles(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        p.arguments = [path, "-name", "._*", "-delete"]
        try? p.run(); p.waitUntilExit()
    }

    func uninstall() {
        let fm = FileManager.default
        for f in Const.payload {
            let p = "\(red4Dir)/\(f)"
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }
        // also clear any wrapper left over from earlier builds
        let wrap = "\(red4Dir)/cyberconsole-launch.sh"
        if fm.fileExists(atPath: wrap) { try? fm.removeItem(atPath: wrap) }
        status = "Uninstalled."
        refresh()
    }

    func stripQuarantine(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", path]
        try? p.run()
        p.waitUntilExit()
    }

    func ensureSteam() {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications.contains { $0.bundleIdentifier == "com.valvesoftware.steam" }
        if !running, let steam = ws.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
            ws.openApplication(at: steam, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func play() {
        guard gameFound else { status = "Game not found."; return }
        guard !busy else { status = "Please wait for the current operation to finish."; return }
        guard gameStore != .unknown else { status = "Unsupported game build. Select a Steam or GOG Cyberpunk 2077 folder."; return }
        if !fullyInstalled() { install() }   // self-heal stale/partial installs
        guard fullyInstalled() else { return }   // install failure must not launch with the wrong command engine
        // pre-flight: every injected dylib must exist, or the game aborts on launch
        let fm = FileManager.default
        let missing = injectDylibs.filter { !fm.fileExists(atPath: "\(red4Dir)/\($0)") }
        guard missing.isEmpty else { status = "Can't launch - missing: \(missing.joined(separator: ", ")). Try Install again."; return }
        guard ensureGameEntitlements() else { return }   // re-sign if a store verify/update reset it
        if gameStore == .gog { launchGame(); return }   // Steam mod preparation is not ported to GOG

        // The mod handoffs live in /tmp, which macOS clears on reboot AND sweeps periodically (its tmp-reaper
        // deletes files untouched for ~3 days, no reboot required). They must exist at launch or mods degrade
        // silently: without cp2077_xl_loc.json every mod LocKey resolves blank, so e.g. Virtual Atelier renders
        // its storefront with NO tab name and NO menu item labels and nothing appears in any log.
        //
        // 2026-08-01: this gate used to be `!mods.isEmpty && !exists(cp2077_xl_items.txt)`, which failed twice
        // over. (1) `mods` is built from red4ext/nightcity/mods manifests, which can be empty while archives are
        // deployed - so needRegen was permanently false and Play never restored anything. (2) it only probed
        // ONE of the five handoffs, so a partial sweep went unnoticed. Regenerate whenever ANY handoff is
        // missing, independent of the manifests. Regen is idempotent and cheap.
        let handoffs = ["/tmp/cp2077_xl_items.txt", "/tmp/cp2077_xl_loc.json", "/tmp/cp2077_xl_paths.txt",
                        "/tmp/cp2077_xl_names.txt", "/tmp/cp2077_xl_meshalias.txt"]
        let needRegen = nctoolPath() != nil && handoffs.contains { !fm.fileExists(atPath: $0) }
        // Script mods (.reds) must be recompiled into the game's script cache before launch; the cache is
        // only read at game startup. A full scc compile is ~0.3s, so run it on every Play when scripts exist.
        let needCompile = hasScripts() && fm.isExecutableFile(atPath: sccGamePath)
        // Plugin-shipped reds (TweakXL / ArchiveXL / Codeware Scripts/*.reds) declare those plugins' native
        // classes and MUST be staged into r6/scripts before scc runs, or the compiled bundle simply omits them
        // and every plugin-scripting mod fails to bind. This is a SEPARATE unconditional step on purpose:
        // folding it into `regen` meant it only ran when /tmp/cp2077_xl_items.txt was missing - i.e. almost
        // never within a session - so the plugin natives silently never reached the bundle. Same skip-logic
        // trap the /tmp enable-flags hit below.
        let canStagePlugins = nctoolPath() != nil
        let sccReady = fm.isExecutableFile(atPath: sccGamePath)
        if needRegen || needCompile || canStagePlugins {
            busy = true; progress = 0
            busyDetail = needRegen ? "Preparing mods…" : "Compiling scripts…"
            status = busyDetail
            DispatchQueue.global(qos: .userInitiated).async {
                if needRegen {
                    self.runNctoolStreaming(["regen", self.gamePath]) { line in
                        if let p = self.parseProgress(line) {
                            DispatchQueue.main.async {
                                self.progress = p.frac
                                self.busyDetail = (p.label.isEmpty ? "Preparing mods" : p.label) + "…"
                            }
                        }
                    }
                }
                if canStagePlugins {
                    self.runNctoolStreaming(["stageplugins", self.gamePath]) { _ in }
                }
                var compileWarn: String? = nil
                // Re-check after staging: the freshly staged plugin reds may be the only scripts present.
                if needCompile || (sccReady && self.hasScripts()) {
                    DispatchQueue.main.async { self.busyDetail = "Compiling scripts…" }
                    compileWarn = self.compileScripts()
                }
                DispatchQueue.main.async {
                    self.busy = false; self.busyDetail = ""; self.progress = 0
                    self.launchGame()
                    // scc keeps the previous good cache on failure, so the game still launches fine -
                    // but tell the user their script mod didn't take.
                    if let w = compileWarn {
                        self.status = "Launched, but a script mod failed to compile (previous scripts kept): \(w)"
                    }
                }
            }
        } else {
            launchGame()
        }
    }

    private func launchGame() {
        if gameStore == .steam {
            ensureSteam()
            // ALWAYS restore the macOS compatibility-layer enable-flags before launch. These live in /tmp and are
            // purged by macOS's periodic tmp-reaper (files unaccessed for ~3 days) even without a reboot. `regen`
            // recreates them, but it only runs when /tmp/cp2077_xl_items.txt is missing - so if the reaper purges
            // the flags but leaves that file, Regen is skipped and the flags stay gone -> the class-validator
            // relaxation (cp2077_bindpatch) is off -> the redscript binder rejects the graph -> SIGTRAP crash at
            // load with no menu. Creating them unconditionally here is immune to the Regen-skip logic.
            for flag in ["cp2077_codeware_real", "cp2077_bindpatch", "cp2077_bindreject",
                         "cp2077_binderr", "cp2077_reglog"] {
                FileManager.default.createFile(atPath: "/tmp/\(flag)", contents: nil)
            }
            // Garment-hook ownership: with the gum gate armed below, RED4ext's manual inline hooks own the
            // garment functions - this flag tells the Frida gadget to step aside (same contract as
            // launch_red4ext_dynamic.sh). Without it the gadget would double-hook the same addresses.
            FileManager.default.createFile(atPath: "/tmp/cp2077_red4ext_owns_garment", contents: nil)
        }
        let inject = injectDylibs.map { "\(red4Dir)/\($0)" }.joined(separator: ":")
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = inject
        env["DYLD_FORCE_FLAT_NAMESPACE"] = "1"
        if gameStore == .steam {
            env["SteamAppId"] = "1091500"
            // Arm the RED4ext loader's hooking gate (manual inline hooks for simple-prologue targets). Without
            // these, every plugin hook (ArchiveXL garment fixes, Codeware's WidgetSpawningService = the
            // dynamic-widget render fix for Codeware UI mods) silently no-ops. Keep this offset list in sync
            // with <GAME>/launch_red4ext_dynamic.sh.
            // THIS LIST IS AN ALLOWLIST AND ITS OMISSIONS ARE SILENT. An address that is missing here still
            // returns success from HookBefore/HookAfter and logs nothing in the plugin - the red4ext log just
            // says "registered at 0x... (gum inactive: no-op)" and the hook never fires. That is exactly how
            // keyboard input stayed dead after inkSystem::ProcessCharacterEvent (0x4887524) was mapped and the
            // service enabled: everything reported OK and no character ever arrived. When a correctly-mapped
            // hook appears to do nothing, CHECK THIS LIST FIRST:
            //   grep -o "registered at 0x[0-9a-f]*" <newest red4ext log>   -> those are the no-op'd ones.
            env["RED4EXT_GUM_HOOKS"] = "scoped"
            env["RED4EXT_GUM_HOOK_OFFSETS"] = "0x1704194,0xcc0710,0xe189f4,0xe16e68,0xe173fc,0xcb12bc,0x370d924,0x3710004,0xae6660,0xae3840,0x4965de0,0x4965ec0,0x4965980,0x4965b38,0x3d9a028,0x49799b8,0x49b888c,0x49a3084,0x47cf584,0x2197aac,0x4887524,0x49bded0"
            env["RED4EXT_GUM_MANUAL_OFFSETS"] = "all"
        } else {
            env.removeValue(forKey: "SteamAppId")
            // These offsets target the Steam executable; never inherit them into the GOG build.
            env.removeValue(forKey: "RED4EXT_GUM_HOOKS")
            env.removeValue(forKey: "RED4EXT_GUM_HOOK_OFFSETS")
            env.removeValue(forKey: "RED4EXT_GUM_MANUAL_OFFSETS")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.currentDirectoryURL = URL(fileURLWithPath: gamePath)
        p.environment = env
        do {
            try p.run()
            status = gameStore == .gog
                ? "Launched - press  `  or  F1  for the console. GOG mod loading is not ported yet."
                : "Launched - your mods load automatically. Press  `  or  F1  for the console."
        } catch {
            status = "Launch failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Mod management (drag-drop installer, powered by the bundled `nctool` engine)

    struct InstalledMod: Identifiable {
        let id = UUID()
        let name: String
        let manifestPath: String
        let fileCount: Int
    }
    @Published var mods: [InstalledMod] = []
    @Published var busy: Bool = false          // an install/remove is running on a background thread
    @Published var busyDetail: String = ""     // live per-step progress shown in the drop zone
    @Published var progress: Double = 0         // 0..1 for the determinate bar (nil-ish when 0 at start)

    // Parse a "[PROGRESS] <fraction> <label>" line emitted by nctool. Returns nil for any other line.
    private func parseProgress(_ line: String) -> (frac: Double, label: String)? {
        guard line.hasPrefix("[PROGRESS] ") else { return nil }
        let rest = line.dropFirst("[PROGRESS] ".count)
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let f = Double(parts.first ?? "") else { return nil }
        return (f, parts.count > 1 ? String(parts[1]) : "")
    }

    // Per-mod manifests (name + the exact deployed files) live here so uninstall is precise.
    var modsManifestDir: String { "\(gamePath)/red4ext/nightcity/mods" }

    // The bundled self-contained `nctool` CLI (the archive/mod engine). In the shipped app it sits in
    // Resources; a dev override lets us test before bundling.
    func nctoolPath() -> String? {
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("nctool/nctool").path   // self-contained publish dir
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        if let dev = ProcessInfo.processInfo.environment["NIGHTCITY_NCTOOL"],
           FileManager.default.isExecutableFile(atPath: dev) { return dev }
        return nil
    }

    @discardableResult
    func runNctool(_ args: [String]) -> (ok: Bool, out: String) {
        guard let tool = nctoolPath() else { return (false, "nctool helper not found.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "Could not run nctool: \(error.localizedDescription)") }
        // Read before waiting so a large output can't deadlock the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    func refreshMods() {
        let fm = FileManager.default
        var found: [InstalledMod] = []
        if let items = try? fm.contentsOfDirectory(atPath: modsManifestDir) {
            for f in items where f.hasSuffix(".json") {
                let mp = "\(modsManifestDir)/\(f)"
                guard let data = fm.contents(atPath: mp),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let name = (obj["name"] as? String) ?? (f as NSString).deletingPathExtension
                let files = (obj["files"] as? [String]) ?? []
                found.append(InstalledMod(name: name, manifestPath: mp, fileCount: files.count))
            }
        }
        mods = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // Like runNctool but streams stdout line-by-line to `onLine` (called on a background thread) so the UI
    // can show live progress. MUST be called off the main thread - availableData blocks until EOF.
    @discardableResult
    func runNctoolStreaming(_ args: [String], onLine: @escaping (String) -> Void) -> (ok: Bool, out: String) {
        guard let tool = nctoolPath() else { return (false, "nctool helper not found.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "Could not run nctool: \(error.localizedDescription)") }
        let fh = pipe.fileHandleForReading
        var all = "", lineBuf = ""
        while true {
            let chunk = fh.availableData
            if chunk.isEmpty { break }              // EOF
            let s = String(data: chunk, encoding: .utf8) ?? ""
            all += s; lineBuf += s
            while let r = lineBuf.range(of: "\n") {
                onLine(String(lineBuf[lineBuf.startIndex..<r.lowerBound]))
                lineBuf.removeSubrange(lineBuf.startIndex..<r.upperBound)
            }
        }
        p.waitUntilExit()
        return (p.terminationStatus == 0, all)
    }

    // Map a raw nctool log line to a short, player-friendly progress phrase (nil = don't surface it).
    private func friendlyProgress(_ line: String) -> String? {
        if line.contains("unzipped") { return "Unpacking…" }
        if line.contains("-> rawrepack") {
            let name = line.replacingOccurrences(of: "[INSTALL] archive ", with: "")
                           .components(separatedBy: " ->").first ?? "archive"
            return "Optimizing \(name)…"
        }
        if line.hasPrefix("[RAWREPACK] re-serialized") { return "Optimizing meshes…" }
        if line.contains("-> ArchiveXL/Bundle") { return "Installing config…" }
        if line.contains("r6/tweaks") { return "Installing records…" }
        if line.hasPrefix("[INSTALL] DONE") { return "Deploying files…" }
        return nil
    }

    // Install a dragged/picked mod (.zip or folder). Runs OFF the main thread (rawrepack of a large archive
    // takes seconds) so the window never beachballs; streams live progress into busyDetail.
    func installMod(from url: URL) {
        guard gameFound else { status = "Game not found."; return }
        guard gameStore == .steam else { status = "Mod installation is not ported to GOG yet."; return }
        guard fullyInstalled() else { status = "Install NightCity Console first, then add mods."; return }
        guard nctoolPath() != nil else { status = "nctool helper missing from the app bundle."; return }
        guard !busy else { status = "Please wait for the current mod to finish installing."; return }
        let base = url.deletingPathExtension().lastPathComponent
        busy = true; progress = 0; busyDetail = "Reading \(base)…"; status = "Installing \(base)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let manifest = "\(self.modsManifestDir)/\(base).json"
            // Phase 1: deploy (nctool install) drives the bar 0 -> 0.6.
            let r = self.runNctoolStreaming(["install", url.path, self.gamePath, manifest]) { line in
                if let p = self.parseProgress(line) {
                    DispatchQueue.main.async {
                        self.progress = p.frac * 0.6
                        if !p.label.isEmpty { self.busyDetail = p.label + "…" }
                    }
                } else if let msg = self.friendlyProgress(line) {
                    DispatchQueue.main.async { self.busyDetail = msg }
                }
            }
            guard r.ok else {
                DispatchQueue.main.async {
                    self.busy = false; self.busyDetail = ""; self.progress = 0
                    self.status = "Couldn't install \(base): \(self.lastLine(r.out))"
                }
                return
            }
            // Phase 2: regenerate game data (nctool regen) drives the bar 0.6 -> 1.0.
            let g = self.runNctoolStreaming(["regen", self.gamePath]) { line in
                if let p = self.parseProgress(line) {
                    DispatchQueue.main.async {
                        self.progress = 0.6 + p.frac * 0.4
                        if !p.label.isEmpty { self.busyDetail = p.label + "…" }
                    }
                }
            }
            // Phase 3: if any .reds are deployed (this mod or an earlier one), recompile the script cache
            // so redscript mods are live on the next launch. ~0.3s.
            var scriptWarn: String? = nil
            if self.hasScripts() && FileManager.default.isExecutableFile(atPath: self.sccGamePath) {
                DispatchQueue.main.async { self.progress = 0.99; self.busyDetail = "Compiling scripts…" }
                scriptWarn = self.compileScripts()
            }
            DispatchQueue.main.async {
                self.busy = false; self.busyDetail = ""; self.progress = 0
                self.refreshMods()
                if let w = scriptWarn {
                    self.status = "Installed \(base), but its scripts failed to compile (mod inactive): \(w)"
                } else {
                    self.status = g.ok ? "Installed \(base) · click Play."
                                       : "Installed \(base) (game-data warning: \(self.lastLine(g.out)))"
                }
            }
        }
    }

    // Uninstall: delete every file the manifest recorded, drop the manifest, regen the handoffs. Off the main
    // thread so the regen doesn't beachball the window.
    func removeMod(_ mod: InstalledMod) {
        guard gameStore == .steam else { status = "Mod management is not ported to GOG yet."; return }
        guard !busy else { status = "Please wait for the current operation to finish."; return }
        busy = true; progress = 0; busyDetail = "Removing \(mod.name)…"; status = "Removing \(mod.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            if let data = fm.contents(atPath: mod.manifestPath),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let files = obj["files"] as? [String] {
                for f in files where fm.fileExists(atPath: f) { try? fm.removeItem(atPath: f) }
            }
            try? fm.removeItem(atPath: mod.manifestPath)
            DispatchQueue.main.async { self.busyDetail = "Updating game data…" }
            self.runNctoolStreaming(["regen", self.gamePath]) { line in
                if let p = self.parseProgress(line) {
                    DispatchQueue.main.async { self.progress = p.frac; if !p.label.isEmpty { self.busyDetail = p.label + "…" } }
                }
            }
            // Recompile the script cache so a removed script mod actually leaves the game - the compiled
            // cache would otherwise keep serving it. With zero script mods left this restores base scripts.
            if FileManager.default.isExecutableFile(atPath: self.sccGamePath) {
                DispatchQueue.main.async { self.busyDetail = "Compiling scripts…" }
                _ = self.compileScripts()
            }
            DispatchQueue.main.async {
                self.busy = false; self.busyDetail = ""; self.progress = 0
                self.refreshMods()
                self.status = "Removed \(mod.name)."
            }
        }
    }

    private func lastLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).last.map(String.init) ?? s
    }
}

struct ContentView: View {
    @StateObject private var m = Model()

    var versionMismatch: Bool {
        guard let v = m.gameVersion else { return false }
        return m.gameFound && v != Const.supportedGameVersion
    }

    var unsupportedStore: Bool { m.gameFound && m.gameStore == .unknown }
    var gogBuild: Bool { m.gameFound && m.gameStore == .gog }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NightCity Console").font(.largeTitle.bold())
            Text("In-game cheat console for Cyberpunk 2077 · macOS").foregroundColor(.secondary)
            Divider()

            if let ut = m.updateText {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(ut, systemImage: "arrow.down.circle.fill").font(.callout).foregroundColor(.green)
                        Spacer()
                        if let u = m.updateURL, let url = URL(string: u) { Link("Download", destination: url) }
                    }
                    // Changelog: collapsed by default. Costs nothing (the body came with the update check),
                    // and answers "do I care about this update?" without cluttering the window when ignored.
                    if let body = m.updateBody {
                        // No isExpanded binding on purpose: DisclosureGroup self-manages its toggle and
                        // starts collapsed. (Avoids @State, which is a macro unavailable under CLT-only.)
                        DisclosureGroup("What's new" + (m.updateTag.map { " in \($0)" } ?? "")) {
                            ScrollView {
                                Text(body)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 120)
                        }
                        .font(.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("GAME FOLDER").font(.caption2).foregroundColor(.secondary)
                HStack {
                    Text(m.gamePath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Browse…") { browse() }
                }
            }

            if versionMismatch, let v = m.gameVersion {
                Label("Detected game v\(v); NightCity Console targets v\(Const.supportedGameVersion). It may not work.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange)
            }
            if unsupportedStore {
                Label("This game build was not recognized as Steam or GOG.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange)
            } else if gogBuild {
                Label("GOG build detected · experimental GOG command engine enabled.",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundColor(.green)
            }

            HStack(spacing: 12) {
                Button(m.installed ? "Reinstall NightCity Console" : "Install") { m.install() }
                    .disabled(!m.gameFound)
                Button("Play  ▶") { m.play() }
                    .disabled(!m.installed || m.busy)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Uninstall NightCity Console") { m.uninstall() }
                    .disabled(!m.installed)
            }

            if m.needsGameAccess {
                HStack(spacing: 10) {
                    Button("Open Privacy Settings") { m.openGameAccessSettings() }
                    Text(m.gameOnExternalDrive
                         ? "Enable NightCity Console under Full Disk Access, then click Install again."
                         : "Enable NightCity Console under App Management, then click Install again.")
                        .font(.caption).foregroundColor(.orange)
                }
            }

            Divider()
            if m.gameStore == .steam {
                HStack {
                    Text("MODS").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("Add Mod…") { addMod() }.disabled(!m.installed || m.busy)
                }
                modDropZone
                modsList
            } else if gogBuild {
                Text("GOG supports the console and item browser. Advanced mod loading is not ported yet.")
                    .font(.callout).foregroundColor(.secondary)
            }

            Spacer()
            HStack {
                Text(m.status).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Link("Commands", destination: URL(string: Const.commandsURL)!)
                Link("♥ Support", destination: URL(string: Const.supportURL)!)
            }
            Text("Steam and experimental GOG support · Cyberpunk 2077 v\(Const.supportedGameVersion)").font(.caption2).foregroundColor(.secondary)
            Text("Single-player only · back up your saves").font(.caption2).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(width: 620, height: 640)
    }

    // Dashed drop target: drag a mod .zip or folder onto it to install. While an install/remove runs it
    // shows a spinner + the live step so the app never looks hung.
    var modDropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundColor(.secondary.opacity(0.5))
            if m.busy {
                VStack(spacing: 6) {
                    ProgressView(value: min(max(m.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 260)
                    Text(m.busyDetail.isEmpty ? "Working…" : m.busyDetail)
                        .font(.callout).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(Int(min(max(m.progress, 0), 1) * 100))%  ·  large mods take a moment")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.down").font(.title3).foregroundColor(.secondary)
                    Text("Drag a mod .zip or folder here").font(.callout).foregroundColor(.secondary)
                    Text(m.installed ? "or click Add Mod above" : "install NightCity Console first")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .frame(height: 70)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            m.busy ? false : handleDrop(providers)
        }
    }

    @ViewBuilder var modsList: some View {
        if m.mods.isEmpty {
            Text("No mods installed yet.").font(.caption).foregroundColor(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(m.mods) { mod in
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox.fill").foregroundColor(.secondary).font(.caption)
                            Text(mod.name).font(.callout)
                            Text("\(mod.fileCount) files").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Button { m.removeMod(mod) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundColor(.red)
                                .disabled(m.busy)
                                .help("Remove \(mod.name)")
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 130)
        }
    }

    func addMod() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Select a mod .zip or mod folder"
        if panel.runModal() == .OK { for url in panel.urls { m.installMod(from: url) } }
    }

    // Resolve dropped file URLs and install each. Returns true if any provider was a file URL.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, url.isFileURL else { return }
                DispatchQueue.main.async { m.installMod(from: url) }
            }
        }
        return accepted
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select your 'Cyberpunk 2077' folder"
        if panel.runModal() == .OK, let url = panel.url { m.setGamePath(url.path) }
    }
}

@main
struct CyberConsoleApp: App {
    var body: some Scene {
        WindowGroup("NightCity Console") {
            ContentView()
        }
    }
}
