import Foundation
import Darwin

@main struct NativeRuntimeTests {
    static var checks = 0
    static func check(_ test: @autoclosure () throws -> Bool, _ message: String = "check failed") throws {
        checks += 1
        if try !test() { throw NativeRuntimeError(message: message) }
    }
    static func refuses(_ message: String = "", _ operation: () throws -> Void) throws {
        checks += 1
        do { try operation() } catch {
            if !message.isEmpty && !error.localizedDescription.localizedCaseInsensitiveContains(message) {
                throw NativeRuntimeError(message: "Wrong refusal: \(error.localizedDescription), wanted \(message)")
            }
            return
        }
        throw NativeRuntimeError(message: "Expected refusal: \(message)")
    }
    static func image() -> Data {
        var bytes = Data(repeating: 0, count: 288)
        func word(_ offset: Int, _ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.replaceSubrange(offset..<offset+4, with: $0) } }
        func wide(_ offset: Int, _ value: UInt64) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.replaceSubrange(offset..<offset+8, with: $0) } }
        word(0, 0xfeedfacf); word(4, 0x0100000c); word(16, 2); word(20, 176)
        word(32, 0x1b); word(36, 24); bytes.replaceSubrange(40..<56, with: Array(UInt8(1)...UInt8(16)))
        word(56, 0x19); word(60, 152); word(120, 1)
        bytes.replaceSubrange(128..<134, with: Data("__text".utf8)); bytes.replaceSubrange(144..<150, with: Data("__TEXT".utf8))
        wide(168, 32); word(176, 256)
        for index in 256..<288 { bytes[index] = UInt8(index & 255) }
        return bytes
    }
    struct Fixture {
        let root: URL, game: URL, resources: URL
        var manifest: NativeRuntimeManifest
        init(_ parent: URL, _ name: String) throws {
            root = parent.appendingPathComponent(name); game = root.appendingPathComponent("game"); resources = root.appendingPathComponent("resources")
            let binary = NativeRuntimeTests.image(), identity = try NativeRuntimeManifest.imageIdentity(binary)
            try NativeRuntimeFiles.write(binary, to: game.appendingPathComponent("Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"))
            var files: [NativeRuntimeManifest.File] = []
            for path in ["red4ext/RED4ext.dylib", NativeRuntimeManifest.frontendPath, NativeRuntimeManifest.runtimePath,
                         "engine/tools/scc", "engine/tools/libscc_lib.dylib", "red4ext/plugins/NightCityRuntime/scripts/NativeSession/Session.reds"] {
                let bytes = Data(("fixture:" + path).utf8)
                try NativeRuntimeFiles.write(bytes, to: resources.appendingPathComponent("native20/payload/" + path))
                files.append(.init(path: path, sha256: NativeRuntimeFiles.hash(bytes), mode: 0o755))
            }
            manifest = NativeRuntimeManifest(schema: 1, backend: "native2.5", gameVersion: "2.5.0",
                executable: .init(relativePath: "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", uuid: identity.uuid, textSHA256: identity.textSHA256),
                files: files, injectedDylibs: ["red4ext/RED4ext.dylib", NativeRuntimeManifest.frontendPath],
                scriptRoots: ["red4ext/plugins/NightCityRuntime/scripts"],
                environment: ["NCC_RUNTIME_PROFILE": "native20-release", "NIGHTCITY_RUNTIME_PROBE": "release20", "NCC_DISABLE_LEGACY_LUA": "1"], previousFiles: [:], retiredFiles: [:], requiresPreparedPackages: true)
            try save()
        }
        func save() throws { try NativeRuntimeFiles.write(JSONEncoder().encode(manifest), to: resources.appendingPathComponent(NativeRuntimeManifest.manifestRelative)) }
        func install(_ didApply: ((Int) throws -> Void)? = nil) throws { try NativeRuntimeInstallation.install(gameRoot: game, resources: resources, gameClosed: { true }, didApply: didApply) }
        func current() throws -> Bool { try NativeRuntimeInstallation.current(gameRoot: game, resources: resources) }
        func read(_ path: String) throws -> Data? { try NativeRuntimeFiles.read(game.appendingPathComponent(path)) }
        func write(_ path: String, _ value: String) throws { try NativeRuntimeFiles.write(Data(value.utf8), to: game.appendingPathComponent(path)) }
        mutating func update() throws {
            let target = manifest.files[0], bytes = Data("second runtime revision".utf8)
            try NativeRuntimeFiles.write(bytes, to: resources.appendingPathComponent("native20/payload/" + target.path))
            var files = manifest.files; files[0] = .init(path: target.path, sha256: NativeRuntimeFiles.hash(bytes), mode: target.mode)
            manifest = NativeRuntimeManifest(schema: manifest.schema, backend: manifest.backend, gameVersion: manifest.gameVersion, executable: manifest.executable,
                files: files, injectedDylibs: manifest.injectedDylibs, scriptRoots: manifest.scriptRoots, environment: manifest.environment,
                previousFiles: manifest.previousFiles, retiredFiles: manifest.retiredFiles, requiresPreparedPackages: true)
            try save()
        }
    }
    static func main() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("nightcity-native-runtime-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        var f = try Fixture(parent, "fresh")
        try f.write("red4ext/cybermodman_names.json", "user weapon definitions")
        try f.write("r6/scripts/Untouched/mod.reds", "user mod")
        try check(!f.current()); try f.install(); try check(f.current())
        try check(f.read("red4ext/cybermodman_names.json") == Data("user weapon definitions".utf8))
        try check(f.read("r6/scripts/Untouched/mod.reds") == Data("user mod".utf8))
        try f.install(); try check(f.current())
        let original = try f.read(f.manifest.files[0].path), receipt = try f.read(NativeRuntimeInstallation.receiptPath)
        try f.update()
        try refuses("injected interruption") { try f.install { index in if index == 0 { throw NativeRuntimeError(message: "injected interruption") } } }
        try check(f.read(f.manifest.files[0].path) == original && f.read(NativeRuntimeInstallation.receiptPath) == receipt)
        try check(f.read(NativeRuntimeInstallation.pendingPath) == nil)
        try f.install(); try check(f.current())
        try f.write(f.manifest.files[0].path, "user edited runtime")
        try refuses("unrecognized or edited") { try f.install() }
        try check(f.read(f.manifest.files[0].path) == Data("user edited runtime".utf8))

        let collision = try Fixture(parent, "collision")
        try collision.write(collision.manifest.files.last!.path, "unowned script")
        try refuses("unrecognized or edited") { try collision.install() }
        try check(collision.read(collision.manifest.files[0].path) == nil)
        try refuses("Quit Cyberpunk") { try NativeRuntimeInstallation.install(gameRoot: collision.game, resources: collision.resources, gameClosed: { false }) }

        let links = try Fixture(parent, "links")
        let foreign = parent.appendingPathComponent("foreign"); try NativeRuntimeFiles.write(Data("foreign".utf8), to: foreign)
        let destination = links.game.appendingPathComponent(links.manifest.files[0].path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: foreign)
        try refuses("Linked runtime") { try links.install() }
        try check(NativeRuntimeFiles.read(foreign) == Data("foreign".utf8))
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.linkItem(at: foreign, to: destination)
        try refuses("Hard-linked") { try links.install() }
        try FileManager.default.removeItem(at: destination)

        let damaged = try Fixture(parent, "damaged")
        var image = image(); image[270] ^= 1
        try NativeRuntimeFiles.write(image, to: damaged.game.appendingPathComponent(damaged.manifest.executable.relativePath))
        try refuses("does not match") { try damaged.install() }
        try refuses("Mach-O") { _ = try NativeRuntimeManifest.imageIdentity(Data("not a game".utf8)) }
        try check(!NativeRuntimeManifest.managedPath("../user-file"))
        try check(!NativeRuntimeManifest.managedPath("red4ext/cybermodman_names.json"))
        try check(!NativeRuntimeManifest.managedPath("red4ext/plugins/NightCityRuntime/module-data/settings.json"))

        let env = try NativeRuntimeLaunch.cleanEnvironment(["HOME": "/Users/test", "PATH": "/tmp/untrusted", "SECRET_TEST": "excluded"])
        try check(env["HOME"] == "/Users/test" && env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin" && env["SECRET_TEST"] == nil)
        for key in ["DYLD_INSERT_LIBRARIES", "RED4EXT_GUM_HOOKS", "NCC_RUNTIME_PROFILE", "FRIDA_TEST", "NIGHTCITY_RUNTIME_BACKEND"] {
            try refuses("Inherited") { _ = try NativeRuntimeLaunch.cleanEnvironment([key: "untrusted"]) }
        }
        let ready = try Fixture(parent, "plan"); try ready.install()
        let plan = try NativeRuntimeLaunch.plan(gameRoot: ready.game, resources: ready.resources, inherited: ["HOME": "/Users/test"], recordPerformance: false)
        try check(plan.environment["NIGHTCITY_RUNTIME_BACKEND"] == "native2.5" && plan.environment["NCC_DISABLE_LEGACY_LUA"] == "1")
        try check(plan.environment["DYLD_INSERT_LIBRARIES"]?.contains("Frida") == false && plan.environment["DYLD_INSERT_LIBRARIES"]?.contains("cyberconsole_overlay") == false)
        try check(plan.environment["NIGHTCITY_RECORD_NATIVE_PERFORMANCE"] == nil && plan.arguments == ["-scriptsBlobPath=\(plan.cache.path)"])
        try refuses("package launch integration") {
            try NativeRuntimeLaunch.launch(gameRoot: ready.game, resources: ready.resources, plan: plan, gameClosed: { true }, started: { _ in throwUnexpected() }, exited: { _, _ in throwUnexpected() })
        }
        // Reconstruct a persisted interruption independently of the installer:
        // target contains new bytes, old bytes and their identity are durable.
        let interrupted = try Fixture(parent, "interrupted"); try interrupted.install()
        let target = interrupted.manifest.files[0].path
        let before = try interrupted.read(target)!, after = Data("interrupted replacement".utf8)
        let recoveryID = UUID().uuidString.lowercased(), recoveryBackup = NativeRuntimeInstallation.backupPath + "/" + recoveryID + "/0"
        try NativeRuntimeFiles.write(before, to: interrupted.game.appendingPathComponent(recoveryBackup))
        let journal = NativeRuntimeInstallation.Journal(schema: 1, id: recoveryID,
            changes: [.init(path: target, before: NativeRuntimeFiles.hash(before), after: NativeRuntimeFiles.hash(after), mode: 0o755, backup: recoveryBackup)])
        let journalBytes = try JSONEncoder().encode(journal)
        try NativeRuntimeFiles.write(after, to: interrupted.game.appendingPathComponent(target))
        try NativeRuntimeFiles.write(journalBytes, to: interrupted.game.appendingPathComponent(NativeRuntimeInstallation.pendingPath))
        try check(!interrupted.current())
        try NativeRuntimeInstallation.recover(gameRoot: interrupted.game, gameClosed: { true })
        try check(interrupted.read(target) == before && interrupted.current())
        // A newer user edit must survive recovery; retain the recovery marker.
        try interrupted.write(target, "changed after interruption")
        try NativeRuntimeFiles.write(journalBytes, to: interrupted.game.appendingPathComponent(NativeRuntimeInstallation.pendingPath))
        try refuses("externally changed") { try NativeRuntimeInstallation.recover(gameRoot: interrupted.game, gameClosed: { true }) }
        try check(interrupted.read(target) == Data("changed after interruption".utf8) && interrupted.read(NativeRuntimeInstallation.pendingPath) == journalBytes)

        let migration = try Fixture(parent, "migration")
        let migrated = migration.manifest.files[0].path, retired = "r6/scripts/NightCityExploration/Old.reds"
        try migration.write(migrated, "accepted old runtime"); try migration.write(retired, "accepted old flight script")
        var manifestJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migration.manifest)) as! [String: Any]
        manifestJSON["previousFiles"] = [migrated: [NativeRuntimeFiles.hash(Data("accepted old runtime".utf8))]]
        manifestJSON["retiredFiles"] = [retired: [NativeRuntimeFiles.hash(Data("accepted old flight script".utf8))]]
        try NativeRuntimeFiles.write(JSONSerialization.data(withJSONObject: manifestJSON), to: migration.resources.appendingPathComponent(NativeRuntimeManifest.manifestRelative))
        try migration.install(); try check(migration.current() && migration.read(retired) == nil)
        try migration.write("red4ext/nightcity-native20/module-data/user/settings.json", "settings survive removal")
        try NativeRuntimeInstallation.remove(gameRoot: migration.game, gameClosed: { true })
        try check(migration.read(migrated) == nil && migration.read(NativeRuntimeInstallation.receiptPath) == nil)
        try check(migration.read("red4ext/nightcity-native20/module-data/user/settings.json") == Data("settings survive removal".utf8))
        try check(FileManager.default.fileExists(atPath: migration.game.appendingPathComponent(NativeRuntimeInstallation.backupPath).path))
        manifestJSON["injectedDylibs"] = ["red4ext/RED4ext.dylib", "red4ext/FridaGadget.dylib"]
        try NativeRuntimeFiles.write(JSONSerialization.data(withJSONObject: manifestJSON), to: migration.resources.appendingPathComponent(NativeRuntimeManifest.manifestRelative))
        try refuses("injection list") { _ = try NativeRuntimeManifest.load(resources: migration.resources) }
        manifestJSON["injectedDylibs"] = ["red4ext/RED4ext.dylib", NativeRuntimeManifest.frontendPath]
        manifestJSON["environment"] = ["NCC_RUNTIME_PROFILE": "native20-development", "NIGHTCITY_RUNTIME_PROBE": "probe76", "NCC_DISABLE_LEGACY_LUA": "1"]
        try NativeRuntimeFiles.write(JSONSerialization.data(withJSONObject: manifestJSON), to: migration.resources.appendingPathComponent(NativeRuntimeManifest.manifestRelative))
        try refuses("release environment") { _ = try NativeRuntimeManifest.load(resources: migration.resources) }
        try refuses("colon or control") { try ready.manifest.verifyGame(root: ready.game.appendingPathComponent("colon:path")) }
        try refuses("colon or control") { _ = try NativeRuntimeManifest.load(resources: ready.resources.appendingPathComponent("newline\npath")) }
        let relativeResources = URL(string: "resources/", relativeTo: URL(fileURLWithPath: ready.root.path, isDirectory: true))!
        try check(relativeResources.baseURL != nil)
        try check(NativeRuntimeManifest.load(resources: relativeResources).1 == NativeRuntimeManifest.load(resources: ready.resources).1)
        let relativeGame = URL(string: "game/", relativeTo: URL(fileURLWithPath: ready.root.path, isDirectory: true))!
        try ready.manifest.verifyGame(root: relativeGame)
        try check(NativeRuntimeFiles.checked(relativeResources, NativeRuntimeManifest.manifestRelative).path == NativeRuntimeFiles.checked(ready.resources, NativeRuntimeManifest.manifestRelative).path)
        try refuses("root=app resources") { _ = try NativeRuntimeManifest.load(resources: URL(string: "Contents/Resources/", relativeTo: URL(string: "https://example.invalid/App/")!)!) }
        try refuses("control=U+000A") { try NativeRuntimeFiles.validateRoot(URL(fileURLWithPath: "/fixture/line\nfeed"), kind: "game") }
        try refuses("colon=true") { try NativeRuntimeFiles.validateRoot(URL(string: "Contents/Resources/", relativeTo: URL(fileURLWithPath: "/fixture/colon:app/", isDirectory: true))!, kind: "app resources") }
        print("\(checks) native runtime installation/identity/environment checks passed; temporary fixtures only, no app/game launched")
    }
    static func throwUnexpected() { fatalError("A test fixture must never launch") }
}
