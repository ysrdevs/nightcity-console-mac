import Foundation

// Package selection is supplied by the reviewed importer integration. Until
// installed, a payload that requires it must refuse, never silently omit mods.
enum NativeRuntimePackagePreparation {
    static var withLaunch: ((_ gameRoot: URL, _ resources: URL, _ launch: () throws -> Void) throws -> Void)?
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
    static func compile(gameRoot: URL, resources: URL, inherited: [String: String]) throws {
        let (manifest, _) = try NativeRuntimeManifest.load(resources: resources)
        let environment = try cleanEnvironment(inherited)
        let sources = try NativeRuntimeFiles.checked(gameRoot, "r6/scripts")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let cache = try NativeRuntimeFiles.checked(gameRoot, NativeRuntimeManifest.cachePath)
        let pathList = try NativeRuntimeFiles.checked(gameRoot, "r6/cache/native20/runtime-script-paths.txt")
        let paths = try manifest.scriptRoots.map { try NativeRuntimeFiles.checked(gameRoot, $0).path }.joined(separator: "\n") + "\n"
        try NativeRuntimeFiles.write(Data(paths.utf8), to: pathList)
        let original = try NativeRuntimeFiles.checked(gameRoot, "r6/cache/final.redscripts")
        guard let originalBytes = try NativeRuntimeFiles.read(original) else { throw NativeRuntimeError(message: "The original game script cache is missing. Verify the game in Steam.") }
        let before = NativeRuntimeFiles.hash(originalBytes)
        let output = try run(executable: NativeRuntimeFiles.checked(gameRoot, "engine/tools/scc"),
            arguments: ["-compile", sources.path, "-outputCacheFile", cache.path, "-compilePathsFile", pathList.path],
            directory: gameRoot, environment: environment)
        try NativeRuntimeFiles.require(try NativeRuntimeFiles.read(original).map(NativeRuntimeFiles.hash) == before, "The compiler changed the original game script cache; launch was refused.")
        try NativeRuntimeFiles.require(output.contains("Output successfully saved") && NativeRuntimeFiles.read(cache) != nil, "The script compiler did not confirm a fresh native cache; launch was refused.")
    }
    static func run(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws -> String {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: bytes, encoding: .utf8) ?? ""
        try NativeRuntimeFiles.require(process.terminationStatus == 0, "\(executable.lastPathComponent) failed: \(String(text.suffix(3000)))")
        return text
    }
    static func launch(gameRoot: URL, resources: URL, plan: Plan, gameClosed: @escaping () -> Bool, started: @escaping (Process) -> Void,
                       exited: @escaping (Int32, Process.TerminationReason) -> Void) throws {
        let (manifest, _) = try NativeRuntimeManifest.load(resources: resources)
        let start = {
            try NativeRuntimeFiles.require(gameClosed(), "Cyberpunk is already running.")
            try manifest.verifyGame(root: gameRoot)
            try NativeRuntimeFiles.require(try NativeRuntimeInstallation.current(gameRoot: gameRoot, resources: resources), "Native runtime files changed before launch.")
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
