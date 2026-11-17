import Foundation
import Darwin

@main struct NativeModPackagesTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String = "check failed") throws {
        checks += 1; if try !value() { throw NativeRuntimeError(message: message) }
    }
    static func refuses(_ text: String, _ action: () throws -> Void) throws {
        checks += 1
        do { try action() } catch { if error.localizedDescription.localizedCaseInsensitiveContains(text) { return }; throw error }
        throw NativeRuntimeError(message: "Expected refusal: " + text)
    }
    static func write(_ root: URL, _ path: String, _ text: String) throws -> URL {
        let url = try NativeRuntimeFiles.checked(root, path); try NativeRuntimeFiles.write(Data(text.utf8), to: url); return url
    }
    static func read(_ root: URL, _ path: String) throws -> String? { try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, path)).map { String(decoding: $0, as: UTF8.self) } }
    static func package(_ root: URL, _ id: String, _ label: String) throws -> NativeModPackages.Package {
        let workspace = NativeModPackages.base + "/imports/" + label + "/" + id
        let source = try write(root, workspace + "/module.ncclua", id + label), digest = try NativeModFiles.identity(source)!
        let preview = NativeModPackages.Preview(schema: 2, packageId: id, version: "fixture", profileId: "fixture", sourcePath: "/fixture", inventorySHA256: digest.sha256,
            dependencies: [], mutablePolicy: "Preserve existing module-data", blockers: [], preparationReady: true)
        return .init(preview: preview, previewSHA256: digest.sha256, workspace: workspace, artifactManifestSHA256: digest.sha256,
            artifacts: [.init(source: "module.ncclua", destination: NativeModPackages.release + "/packages/" + id + "/module.ncclua", size: digest.size, sha256: digest.sha256, mode: 0o600)], companionPreviewSHA256: nil)
    }
    static func transaction(_ root: URL) throws {
        let source = try write(root, "input", "new"), old = try write(root, "r6/scripts/owned.reds", "old")
        let before = try NativeModFiles.identity(old)!, after = try NativeModFiles.identity(source)!
        let desired = NativeModTransaction.Desired(path: "r6/scripts/owned.reds", source: source, identity: after, mode: 0o600)
        try refuses("unowned") { try NativeModTransaction.apply(root: root, desired: [desired], owned: [:], gameClosed: { true }) }
        try check(read(root, desired.path) == "old")
        try refuses("Close Cyberpunk") { try NativeModTransaction.apply(root: root, desired: [desired], owned: [desired.path: before.sha256], gameClosed: { false }) }
        var validatorSawNew = false
        try refuses("compile failure") {
            try NativeModTransaction.apply(root: root, desired: [desired], owned: [desired.path: before.sha256], gameClosed: { true }, validateStaged: {
                validatorSawNew = try read(root, desired.path) == "new"
                throw NativeRuntimeError(message: "compile failure")
            })
        }
        try check(validatorSawNew); try check(read(root, desired.path) == "old"); try check(read(root, NativeModTransaction.pending) == nil)
        try refuses("interruption") {
            try NativeModTransaction.apply(root: root, desired: [desired], owned: [desired.path: before.sha256], gameClosed: { true }, didApply: { _ in throw NativeRuntimeError(message: "interruption") })
        }
        try check(read(root, desired.path) == "old")
        try NativeModTransaction.apply(root: root, desired: [desired], owned: [desired.path: before.sha256], gameClosed: { true })
        try check(read(root, desired.path) == "new")
        try refuses("duplicate") { try NativeModTransaction.apply(root: root, desired: [desired, desired], owned: [:], gameClosed: { true }) }
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try refuses("inspect") { _ = try NativeModFiles.identity(link) }
        let hardlink = root.appendingPathComponent("hardlink"); try FileManager.default.linkItem(at: source, to: hardlink)
        try refuses("link") { _ = try NativeModFiles.identity(hardlink) }; try FileManager.default.removeItem(at: hardlink)
        // Preserve a concurrent external edit and retain evidence when rollback
        // cannot prove that it still owns the installed bytes.
        let nextSource = try write(root, "next", "third"), nextID = try NativeModFiles.identity(nextSource)!
        try refuses("recovery stopped") {
            try NativeModTransaction.apply(root: root, desired: [.init(path: desired.path, source: nextSource, identity: nextID, mode: 0o600)], owned: [desired.path: after.sha256], gameClosed: { true }, didApply: { _ in
                _ = try write(root, desired.path, "external edit"); throw NativeRuntimeError(message: "interruption")
            })
        }
        try check(read(root, desired.path) == "external edit"); try check(read(root, NativeModTransaction.pending) != nil)
        try refuses("preserved") { try NativeModTransaction.recover(root: root) }
        _ = try write(root, desired.path, "third"); try NativeModTransaction.recover(root: root)
        try check(read(root, desired.path) == "new"); try check(read(root, NativeModTransaction.pending) == nil)
    }
    static func packages(_ root: URL) throws {
        let work = root.appendingPathComponent("metadata"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        _ = try write(root, "red4ext/nightcity-native20/module-data/immersive_third_person/config.json", "user settings")
        _ = try write(root, "red4ext/cybermodman_names.json", "user creator")
        let ns = try package(root, "nativeSettings", "first"), vcc = try package(root, "VehicleCallCost", "first"), itp = try package(root, "immersive_third_person", "first")
        try refuses("dependency") { try NativeModPackages.validate([itp]) }
        try refuses("Duplicate") { try NativeModPackages.validate([ns, ns]) }
        try check(NativeModPackages.readSelection(root) == nil)
        var sawOldSelection = false
        try NativeModPackages.activate([ns], current: nil, root: root, workspace: work, gameClosed: { true }, validateScripts: { sawOldSelection = try NativeModPackages.readSelection(root) == nil })
        try check(sawOldSelection)
        let first = try NativeModPackages.readSelection(root)!
        try check(first.packages.count == 1)
        var launched = 0
        try NativeModPackages.withLaunch(gameRoot: root, resources: root) {
            let bytes = try NativeRuntimeFiles.read(root.appendingPathComponent(NativeModPackages.release + "/release-launch.nccset"))!
            try check(bytes.count == 73); try check(bytes.prefix(8) == Data("NCCREL1\0".utf8)); try check(bytes[8] == 1); launched += 1
        }
        try check(launched == 1)
        try NativeModPackages.activate([ns, vcc, itp], current: first, root: root, workspace: work, gameClosed: { true }, validateScripts: {})
        try NativeModPackages.withLaunch(gameRoot: root, resources: root) {
            let bytes = try NativeRuntimeFiles.read(root.appendingPathComponent(NativeModPackages.release + "/release-launch.nccset"))!
            try check(bytes[8] == 7)
        }
        try refuses("dependent mods") { try NativeModPackages.remove("nativeSettings", gameRoot: root, gameClosed: { true }, validateScripts: {}) }
        try NativeModPackages.restorePrevious(gameRoot: root, gameClosed: { true }, validateScripts: {})
        try check(NativeModPackages.readSelection(root)?.packages.count == 1)
        try NativeModPackages.remove("nativeSettings", gameRoot: root, gameClosed: { true }, validateScripts: {})
        try check(NativeModPackages.readSelection(root)?.packages.isEmpty == true)
        try NativeModPackages.restorePrevious(gameRoot: root, gameClosed: { true }, validateScripts: {})
        try check(NativeModPackages.readSelection(root)?.packages.count == 1)
        try check(read(root, vcc.artifacts[0].destination) == nil)
        try check(read(root, "red4ext/nightcity-native20/module-data/immersive_third_person/config.json") == "user settings")
        try check(read(root, "red4ext/cybermodman_names.json") == "user creator")
        _ = try write(root, ns.artifacts[0].destination, "external")
        try refuses("changed") { try NativeModPackages.withLaunch(gameRoot: root, resources: root) { launched += 1 } }
        try check(launched == 1)
        let source = root.appendingPathComponent(ns.workspace + "/" + ns.artifacts[0].source)
        try NativeModFiles.copy(source, to: root.appendingPathComponent(ns.artifacts[0].destination), expected: .init(sha256: ns.artifacts[0].sha256, size: ns.artifacts[0].size))
        let current = try NativeModPackages.readSelection(root)!
        try NativeModPackages.activate([], current: current, root: root, workspace: work, gameClosed: { true }, validateScripts: {})
        try NativeModPackages.withLaunch(gameRoot: root, resources: root) {
            let bytes = try NativeRuntimeFiles.read(root.appendingPathComponent(NativeModPackages.release + "/release-launch.nccset"))!
            try check(bytes[8] == 0)
        }
        try check(read(root, ns.artifacts[0].destination) == nil)
    }
    static func commands(_ root: URL) throws {
        let env = ["PATH": "/usr/bin:/bin"]
        let result = try NativeRuntimeCommand.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf success"], directory: root, environment: env)
        try check(String(decoding: result, as: UTF8.self) == "success")
        try refuses("output limit") { _ = try NativeRuntimeCommand.run(URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], environment: env, maximumOutput: 4096, timeout: 2) }
        let start = Date()
        try refuses("time limit") { _ = try NativeRuntimeCommand.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & exit 0"], environment: env, timeout: 0.2) }
        try check(Date().timeIntervalSince(start) < 2, "Inherited child pipe exceeded the deadline")
        try refuses("failed") { _ = try NativeRuntimeCommand.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo expected_failure; exit 3"], environment: env) }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("nightcity-native-packages-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try transaction(root.appendingPathComponent("transactions")); try packages(root.appendingPathComponent("packages")); try commands(root)
        print("Native mod package tests passed: \(checks) checks (temporary fixtures only).")
    }
}
