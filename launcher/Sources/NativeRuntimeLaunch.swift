import Foundation
import Darwin

// Package selection is supplied by the reviewed importer integration. Until
// installed, a payload that requires it must refuse, never silently omit mods.
enum NativeRuntimePackagePreparation {
    static var withLaunch: ((_ gameRoot: URL, _ resources: URL, _ launch: () throws -> Void) throws -> Void)?
}

enum NativeScriptCacheUpgrade {
    // Verified original script cache for the exact macOS Steam 2.5 game image
    // accepted by the native manifest. Older SCC installs can leave a compiled
    // final.redscripts beside this backup; selecting a separate output restores it.
    static let vanillaSHA256 = "7a5a798fe88c5e4afd64b91e265deccd091c2c5c94241003a11abbd70fb6785c"

    static func allowsOriginal(before: String, legacyBackupBefore: String?, after: String?) -> Bool {
        if after == before { return true }
        return legacyBackupBefore == vanillaSHA256 && after == vanillaSHA256
    }
}

enum NativeRuntimeSidecars {
    // AppleDouble v2: header, bounded entry table and entries contained in the
    // file. A ._ filename alone never authorizes deleting player content.
    static func isAppleDouble(_ data: Data) -> Bool {
        guard data.count >= 26 else { return false }
        func word(_ offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        }
        guard word(0) == 0x00051607, word(4) == 0x00020000 else { return false }
        let count = Int(data[24]) << 8 | Int(data[25])
        guard (1...64).contains(count), 26 + count * 12 <= data.count else { return false }
        let tableEnd = 26 + count * 12
        var ids = Set<UInt32>(), ranges: [Range<Int>] = []
        for index in 0..<count {
            let entry = 26 + index * 12
            let id = word(entry), offset = Int(word(entry + 4)), size = Int(word(entry + 8))
            guard id != 0, ids.insert(id).inserted, offset >= tableEnd, offset <= data.count,
                  size <= data.count - offset else { return false }
            let range = offset..<(offset + size)
            guard ranges.allSatisfy({ !$0.overlaps(range) }) else { return false }
            ranges.append(range)
        }
        return true
    }

    @discardableResult
    static func removeRecognized(gameRoot: URL, relativeRoots: [String]) throws -> [String] {
        let fm = FileManager.default
        var candidates: [String: Data] = [:]
        func collect(_ relativeRoot: String) throws {
            let root = try NativeRuntimeFiles.checked(gameRoot, relativeRoot)
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT { return }
            try NativeRuntimeFiles.require(fd >= 0, "Cannot inspect metadata sidecars in \(relativeRoot).")
            guard let directory = fdopendir(fd) else { close(fd); throw NativeRuntimeError(message: "Cannot enumerate metadata sidecars in \(relativeRoot).") }
            defer { closedir(directory) }
            // Foundation hides ._ entries even without skipsHiddenFiles. POSIX
            // enumeration is required to see the metadata that SCC still reads.
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    try NativeRuntimeFiles.require(errno == 0, "Cannot finish metadata enumeration in \(relativeRoot).")
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var metadata = stat()
                try NativeRuntimeFiles.require(fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0, "Cannot inspect metadata entry in \(relativeRoot).")
                let relative = relativeRoot + "/" + name
                if metadata.st_mode & S_IFMT == S_IFDIR { try collect(relative); continue }
                guard name.hasPrefix("._"), metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_nlink == 1, (26...(16 * 1024 * 1024)).contains(metadata.st_size) else { continue }
                let checked = try NativeRuntimeFiles.checked(gameRoot, relative)
                guard let bytes = try NativeRuntimeFiles.read(checked, maximum: 16 * 1024 * 1024), isAppleDouble(bytes) else { continue }
                candidates[relative] = bytes
            }
        }
        for relativeRoot in Set(relativeRoots).sorted() { try collect(relativeRoot) }
        for (relative, bytes) in candidates.sorted(by: { $0.key < $1.key }) {
            let path = try NativeRuntimeFiles.checked(gameRoot, relative)
            try NativeRuntimeFiles.require(try NativeRuntimeFiles.read(path, maximum: 16 * 1024 * 1024) == bytes,
                "Metadata sidecar changed before cleanup: \(relative)")
            try fm.removeItem(at: path)
        }
        return candidates.keys.sorted()
    }
}

enum NativeRuntimeLaunch {
    struct Plan {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let cache: URL
    }
    static func cleanEnvironment(_ inherited: [String: String]) throws -> [String: String] {
        let forbidden = inherited.keys.filter { key in ["DYLD_", "RED4EXT_", "NCC_", "FRIDA_", "NIGHTCITY_"].contains(where: key.hasPrefix) }
        try NativeRuntimeFiles.require(forbidden.isEmpty, "Inherited runtime/injection controls were refused: \(forbidden.sorted().joined(separator: ", ")). Open NightCity Console normally to select its native backend.")
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_CTYPE"] { environment[key] = inherited[key] }
        return environment
    }
    static func plan(gameRoot: URL, resources: URL, inherited: [String: String], recordPerformance: Bool) throws -> Plan {
        let (manifest, _) = try NativeRuntimeManifest.load(resources: resources)
        try manifest.verifyGame(root: gameRoot)
        try NativeRuntimeFiles.require(try NativeRuntimeInstallation.current(gameRoot: gameRoot, resources: resources), "Native runtime installation is incomplete or changed. Click Install before Play.")
        var environment = try cleanEnvironment(inherited)
        environment.merge(manifest.environment, uniquingKeysWith: { _, selected in selected })
        environment["DYLD_INSERT_LIBRARIES"] = try manifest.injectedDylibs.map { try NativeRuntimeFiles.checked(gameRoot, $0).path }.joined(separator: ":")
        environment["DYLD_FORCE_FLAT_NAMESPACE"] = "1"
        environment["SteamAppId"] = "1091500"
        environment["NIGHTCITY_RUNTIME_BACKEND"] = "native2.5"
        environment["NCC_DISABLE_LEGACY_LUA"] = "1"
        environment["NCC_DATA_DIR"] = try NativeRuntimeFiles.checked(gameRoot, NativeRuntimeManifest.dataPath).path
        if recordPerformance { environment["NIGHTCITY_RECORD_NATIVE_PERFORMANCE"] = "1" }
        let cache = try NativeRuntimeFiles.checked(gameRoot, NativeRuntimeManifest.cachePath)
        return Plan(executable: try NativeRuntimeFiles.checked(gameRoot, manifest.executable.relativePath), arguments: ["-scriptsBlobPath=\(cache.path)"], environment: environment, cache: cache)
    }
    static func ensureEntitlements(gameRoot: URL, inherited: [String: String]) throws {
        let environment = try cleanEnvironment(inherited)
        try NativeRuntimeSidecars.removeRecognized(gameRoot: gameRoot, relativeRoots: ["Cyberpunk2077.app"])
        let executable = try NativeRuntimeFiles.checked(gameRoot, "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077")
        let tool = URL(fileURLWithPath: "/usr/bin/codesign")
        let existing = try NativeRuntimeCommand.run(tool, arguments: ["-d", "--entitlements", ":-", executable.path], environment: environment, timeout: 30)
        let text = String(decoding: existing, as: UTF8.self)
        if text.contains("allow-jit") && text.contains("allow-dyld-environment-variables") && text.contains("disable-library-validation") { return }
        let keys = ["com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-unsigned-executable-memory", "com.apple.security.cs.disable-executable-page-protection", "com.apple.security.cs.disable-library-validation"]
        let data = try PropertyListSerialization.data(fromPropertyList: Dictionary(uniqueKeysWithValues: keys.map { ($0, true) }), format: .xml, options: 0)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nightcity-native-entitlements-" + UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try NativeRuntimeFiles.write(data, to: temporary)
        _ = try NativeRuntimeCommand.run(tool, arguments: ["-f", "-s", "-", "--entitlements", temporary.path, executable.path], environment: environment, timeout: 60)
    }

    static func stagePluginScripts(gameRoot: URL, inherited: [String: String]) throws -> [String] {
        let fm = FileManager.default, environment = try cleanEnvironment(inherited)
        try NativeRuntimeSidecars.removeRecognized(gameRoot: gameRoot, relativeRoots: ["red4ext/plugins"])
        let plugins = try NativeRuntimeFiles.checked(gameRoot, "red4ext/plugins")
        let checker = try NativeRuntimeFiles.checked(gameRoot, "red4ext/bin/red4ext_plugin_check")
        let database = try NativeRuntimeFiles.checked(gameRoot, "red4ext/bin/x64/cyberpunk2077_addresses.json")
        var sources: [String: URL] = [:], accepted: [String: URL] = [:], refused: [String] = []
        for name in (try fm.contentsOfDirectory(atPath: plugins.path)).sorted() where !name.hasPrefix(".") {
            let directory = try NativeRuntimeFiles.checked(gameRoot, "red4ext/plugins/" + name)
            let scripts = directory.appendingPathComponent("Scripts")
            // Runtime scripts are supplied separately with compilePathsFile.
            if name != "NightCityRuntime" && fm.fileExists(atPath: scripts.path) { sources[name] = scripts }
            let dylibs = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".dylib") && !$0.hasPrefix(".") }.sorted()
            guard !dylibs.isEmpty else { continue }
            do {
                _ = try NativeRuntimeCommand.run(checker, arguments: [database.path] + dylibs.map { directory.appendingPathComponent($0).path },
                    directory: gameRoot, environment: environment, maximumOutput: 1024 * 1024, timeout: 30)
                if let source = sources[name] { accepted[name] = source }
            } catch { refused.append(name) }
        }
        try PluginScriptStager.reconcile(accepted: accepted, knownSources: sources,
            scriptsRoot: NativeRuntimeFiles.checked(gameRoot, "r6/scripts"), manifestURL: NativeRuntimeFiles.checked(gameRoot, "red4ext/nightcity-plugin-scripts.json"))
        return refused
    }

    static func compile(gameRoot: URL, resources: URL, inherited: [String: String]) throws {
        let (manifest, _) = try NativeRuntimeManifest.load(resources: resources)
        let environment = try cleanEnvironment(inherited)
        // SCC also reads *.toml from redsUserHints when explaining a compile
        // failure. Binary AppleDouble copies there can obscure the real error.
        try NativeRuntimeSidecars.removeRecognized(gameRoot: gameRoot,
            relativeRoots: ["r6/scripts", "r6/config/redsUserHints"] + manifest.scriptRoots)
        let sources = try NativeRuntimeFiles.checked(gameRoot, "r6/scripts")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let cache = try NativeRuntimeFiles.checked(gameRoot, NativeRuntimeManifest.cachePath)
        let pathList = try NativeRuntimeFiles.checked(gameRoot, "r6/cache/native20/runtime-script-paths.txt")
        let paths = try manifest.scriptRoots.map { try NativeRuntimeFiles.checked(gameRoot, $0).path }.joined(separator: "\n") + "\n"
        try NativeRuntimeFiles.write(Data(paths.utf8), to: pathList)
        let original = try NativeRuntimeFiles.checked(gameRoot, "r6/cache/final.redscripts")
        guard let originalBytes = try NativeRuntimeFiles.read(original) else { throw NativeRuntimeError(message: "The original game script cache is missing. Verify the game in Steam.") }
        let before = NativeRuntimeFiles.hash(originalBytes)
        let legacyBackup = try NativeRuntimeFiles.checked(gameRoot, "r6/cache/final.redscripts.bk")
        let legacyBackupBefore = try NativeRuntimeFiles.read(legacyBackup).map(NativeRuntimeFiles.hash)
        let output = try run(executable: NativeRuntimeFiles.checked(gameRoot, "engine/tools/scc"),
            arguments: ["-compile", sources.path, "-outputCacheFile", cache.path, "-compilePathsFile", pathList.path],
            directory: gameRoot, environment: environment)
        let after = try NativeRuntimeFiles.read(original).map(NativeRuntimeFiles.hash)
        try NativeRuntimeFiles.require(NativeScriptCacheUpgrade.allowsOriginal(before: before, legacyBackupBefore: legacyBackupBefore, after: after),
            "The compiler changed the original game script cache unexpectedly; launch was refused.")
        try NativeRuntimeFiles.require(output.contains("Output successfully saved") && NativeRuntimeFiles.read(cache) != nil, "The script compiler did not confirm a fresh native cache; launch was refused.")
    }
    static func run(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws -> String {
        let bytes = try NativeRuntimeCommand.run(executable, arguments: arguments, directory: directory,
            environment: environment, maximumOutput: 1024 * 1024, timeout: 120)
        return String(decoding: bytes, as: UTF8.self)
    }
    static func launch(gameRoot: URL, resources: URL, plan: Plan, gameClosed: @escaping () -> Bool, started: @escaping (Process) -> Void,
                       exited: @escaping (Int32, Process.TerminationReason) -> Void) throws {
        let (manifest, _) = try NativeRuntimeManifest.load(resources: resources)
        let start = {
            try NativeRuntimeFiles.require(gameClosed(), "Cyberpunk is already running.")
            try manifest.verifyGame(root: gameRoot)
            try NativeRuntimeFiles.require(try NativeRuntimeInstallation.current(gameRoot: gameRoot, resources: resources), "Native runtime files changed before launch.")
            try NativeRuntimeSidecars.removeRecognized(gameRoot: gameRoot, relativeRoots: ["archive/Mac/mod", "r6/tweaks"])
            let refused = try stagePluginScripts(gameRoot: gameRoot, inherited: ProcessInfo.processInfo.environment)
            try NativeRuntimeFiles.require(refused.isEmpty, "Native plugin verification refused: \(refused.joined(separator: ", ")).")
            // Selection lock remains held through compile and process ownership
            // publication, so Apply cannot swap sources beneath this cache.
            try compile(gameRoot: gameRoot, resources: resources, inherited: ProcessInfo.processInfo.environment)
            try NativeRuntimeFiles.require(gameClosed(), "Cyberpunk started while preparing its script cache.")
            let process = Process(); process.executableURL = plan.executable; process.arguments = plan.arguments
            process.currentDirectoryURL = gameRoot; process.environment = plan.environment
            let logs = try NativeRuntimeFiles.checked(gameRoot, NativeRuntimeManifest.dataPath + "/logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent("game-\(UUID().uuidString.lowercased()).log")
            try NativeRuntimeFiles.write(Data(), to: log)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle; process.standardError = handle
            process.terminationHandler = { process in
                let record = ["schema": 1, "pid": Int(process.processIdentifier), "status": Int(process.terminationStatus),
                    "reason": process.terminationReason == .exit ? "exit" : "signal"] as [String: Any]
                if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                    try? NativeRuntimeFiles.write(data, to: log.appendingPathExtension("exit.json"))
                }
                try? handle.close(); exited(process.terminationStatus, process.terminationReason)
            }
            do { try process.run(); started(process) }
            catch { try? handle.close(); throw error }
        }
        if manifest.requiresPreparedPackages {
            guard let prepare = NativeRuntimePackagePreparation.withLaunch else {
                throw NativeRuntimeError(message: "This native candidate requires the reviewed mod-package launch integration, which is not bundled yet. Launch was stopped; no legacy backend or unselected mods were loaded.")
            }
            try prepare(gameRoot, resources, start)
        } else { try start() }
    }
}
