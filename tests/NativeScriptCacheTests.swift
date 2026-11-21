import Foundation

@main struct NativeScriptCacheTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw NativeRuntimeError(message: message) }
    }
    static func refuses(_ message: String, _ action: () throws -> Void) throws {
        checks += 1
        do { try action() }
        catch {
            guard error.localizedDescription.contains(message) else { throw error }
            return
        }
        throw NativeRuntimeError(message: "Expected refusal: " + message)
    }
    static func write(_ data: Data, _ url: URL, mode: Int = 0o600) throws {
        try NativeRuntimeFiles.write(data, to: url, mode: mode)
    }
    static func appleDouble() -> Data {
        var data = Data(repeating: 0, count: 39)
        func word(_ offset: Int, _ value: UInt32) {
            for index in 0..<4 { data[offset + index] = UInt8((value >> (24 - index * 8)) & 255) }
        }
        word(0, 0x00051607); word(4, 0x00020000); data[25] = 1
        word(26, 2); word(30, 38); word(34, 1); data[38] = 255
        return data
    }
    static func fixture(_ parent: URL, name: String, compiler: String) throws -> (URL, URL) {
        let root = parent.appendingPathComponent(name), game = root.appendingPathComponent("game with spaces")
        let resources = root.appendingPathComponent("resources")
        let names = ["red4ext/RED4ext.dylib", NativeRuntimeManifest.frontendPath, NativeRuntimeManifest.runtimePath,
                     "engine/tools/scc", "engine/tools/libscc_lib.dylib", "red4ext/plugins/NightCityRuntime/scripts/Smoke.reds"]
        let manifest: [String: Any] = [
            "schema": 1, "backend": "native2.5", "gameVersion": "2.5.0",
            "executable": ["relativePath": "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077",
                           "uuid": "12345678-1234-1234-1234-123456789ABC", "textSHA256": String(repeating: "a", count: 64)],
            "files": names.map { ["path": $0, "sha256": String(repeating: "b", count: 64), "mode": 493] as [String: Any] },
            "injectedDylibs": ["red4ext/RED4ext.dylib", NativeRuntimeManifest.frontendPath],
            "scriptRoots": ["red4ext/plugins/NightCityRuntime/scripts"],
            "environment": ["NCC_RUNTIME_PROFILE": "native20-release", "NIGHTCITY_RUNTIME_PROBE": "release20", "NCC_DISABLE_LEGACY_LUA": "1"],
            "previousFiles": [:] as [String: [String]], "retiredFiles": [:] as [String: [String]], "requiresPreparedPackages": true
        ]
        try write(JSONSerialization.data(withJSONObject: manifest), resources.appendingPathComponent(NativeRuntimeManifest.manifestRelative))
        try write(Data("original fixture".utf8), game.appendingPathComponent("r6/cache/final.redscripts"))
        try write(Data(("#!/bin/sh\nset -eu\n" + compiler + "\n").utf8), game.appendingPathComponent("engine/tools/scc"), mode: 0o755)
        return (game, resources)
    }
    static func main() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("nightcity-cache-upgrade-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let vanilla = NativeScriptCacheUpgrade.vanillaSHA256, old = String(repeating: "1", count: 64)
        try check(NativeScriptCacheUpgrade.allowsOriginal(before: old, legacyBackupBefore: nil, after: old), "Unchanged original must remain accepted")
        try check(NativeScriptCacheUpgrade.allowsOriginal(before: old, legacyBackupBefore: vanilla, after: vanilla), "Verified vanilla backup restoration must be accepted")
        try check(!NativeScriptCacheUpgrade.allowsOriginal(before: old, legacyBackupBefore: nil, after: vanilla), "A new vanilla-looking result without the preexisting backup must refuse")
        try check(!NativeScriptCacheUpgrade.allowsOriginal(before: old, legacyBackupBefore: old, after: vanilla), "An unknown backup must not authorize restoration")
        try check(!NativeScriptCacheUpgrade.allowsOriginal(before: old, legacyBackupBefore: vanilla, after: String(repeating: "2", count: 64)), "A changed nonvanilla original must refuse")
        try check(!NativeScriptCacheUpgrade.allowsOriginal(before: old, legacyBackupBefore: vanilla, after: nil), "A missing original must refuse")
        let success = "printf 'compiled fixture' > r6/cache/native20/final.redscripts\nprintf 'Output successfully saved\\n'"
        let unchanged = try fixture(parent, name: "unchanged", compiler: success)
        try NativeRuntimeLaunch.compile(gameRoot: unchanged.0, resources: unchanged.1, inherited: [:])
        try check(try NativeRuntimeFiles.read(unchanged.0.appendingPathComponent("r6/cache/final.redscripts")) == Data("original fixture".utf8), "Normal compilation changed its original")
        let changed = try fixture(parent, name: "unexpected-change", compiler: "printf 'unexpected change' > r6/cache/final.redscripts\n" + success)
        try refuses("changed the original game script cache unexpectedly") {
            try NativeRuntimeLaunch.compile(gameRoot: changed.0, resources: changed.1, inherited: [:])
        }
        let missing = try fixture(parent, name: "missing-native-output", compiler: "printf 'Output successfully saved\\n'")
        try refuses("did not confirm a fresh native cache") {
            try NativeRuntimeLaunch.compile(gameRoot: missing.0, resources: missing.1, inherited: [:])
        }
        let unconfirmed = try fixture(parent, name: "unconfirmed-output", compiler: "printf 'compiled fixture' > r6/cache/native20/final.redscripts")
        try refuses("did not confirm a fresh native cache") {
            try NativeRuntimeLaunch.compile(gameRoot: unconfirmed.0, resources: unconfirmed.1, inherited: [:])
        }
        let linked = try fixture(parent, name: "linked-backup", compiler: success)
        let foreign = parent.appendingPathComponent("foreign-backup")
        try write(Data("foreign".utf8), foreign)
        try FileManager.default.createSymbolicLink(at: linked.0.appendingPathComponent("r6/cache/final.redscripts.bk"), withDestinationURL: foreign)
        try refuses("Linked runtime path") {
            try NativeRuntimeLaunch.compile(gameRoot: linked.0, resources: linked.1, inherited: [:])
        }
        try check(try NativeRuntimeFiles.read(foreign) == Data("foreign".utf8), "Linked backup target changed")

        let sidecars = parent.appendingPathComponent("sidecar preservation")
        let metadata = appleDouble()
        try check(NativeRuntimeSidecars.isAppleDouble(metadata), "Valid metadata header was refused")
        var damagedMetadata = metadata; damagedMetadata[34] = 1
        try check(!NativeRuntimeSidecars.isAppleDouble(damagedMetadata), "Out-of-file entry range was accepted")
        var wrongVersion = metadata; wrongVersion[5] = 1
        try check(!NativeRuntimeSidecars.isAppleDouble(wrongVersion), "Wrong AppleDouble version was accepted")
        try check(!NativeRuntimeSidecars.isAppleDouble(metadata.prefix(25)), "Truncated AppleDouble header was accepted")
        let retained = ["r6/scripts/Primary.reds": metadata,
                        "r6/scripts/._player.reds": Data("An intentionally named player file must remain unchanged.".utf8),
                        "r6/scripts/._damaged.reds": damagedMetadata,
                        "r6/cache/._outside-scan": metadata]
        for (relative, bytes) in retained { try write(bytes, sidecars.appendingPathComponent(relative)) }
        try write(metadata, sidecars.appendingPathComponent("r6/scripts/Nested/._Fixture.reds"))
        let metadataTarget = sidecars.appendingPathComponent("metadata-target")
        try write(metadata, metadataTarget)
        try FileManager.default.createSymbolicLink(at: sidecars.appendingPathComponent("r6/scripts/._linked.reds"), withDestinationURL: metadataTarget)
        let removed = try NativeRuntimeSidecars.removeRecognized(gameRoot: sidecars, relativeRoots: ["r6/scripts", "r6/scripts/Nested", "missing"])
        try check(removed == ["r6/scripts/Nested/._Fixture.reds"], "Only the valid sidecar should be removed once: \(removed)")
        for (relative, bytes) in retained {
            try check(try NativeRuntimeFiles.read(sidecars.appendingPathComponent(relative)) == bytes, "User content changed during metadata cleanup: " + relative)
        }
        try check(try NativeRuntimeFiles.read(metadataTarget) == metadata, "Linked metadata target changed")
        try check(FileManager.default.fileExists(atPath: sidecars.appendingPathComponent("r6/scripts/._linked.reds").path), "Metadata symlink was removed")

        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            guard arguments.count == 2 else { throw NativeRuntimeError(message: "Optional arguments: signed-app-resources known-vanilla-final.redscripts") }
            try realCompiler(parent, resources: URL(fileURLWithPath: arguments[0]), vanillaCache: URL(fileURLWithPath: arguments[1]))
        }
        print("\(checks) cache upgrade checks passed; temporary fixtures only, no game launched")
    }
    static func realCompiler(_ parent: URL, resources: URL, vanillaCache: URL) throws {
        guard let vanilla = try NativeRuntimeFiles.read(vanillaCache), NativeRuntimeFiles.hash(vanilla) == NativeScriptCacheUpgrade.vanillaSHA256 else {
            throw NativeRuntimeError(message: "The read-only cache input is not the verified Steam 2.5 vanilla cache")
        }
        let (manifest, _) = try NativeRuntimeManifest.load(resources: resources)
        let game = parent.appendingPathComponent("real SCC upgrade with spaces")
        for name in ["scc", "libscc_lib.dylib"] {
            let relative = "engine/tools/" + name
            guard let expected = manifest.files.first(where: { $0.path == relative }),
                  let bytes = try NativeRuntimeFiles.read(resources.appendingPathComponent("native20/payload/" + relative)),
                  NativeRuntimeFiles.hash(bytes) == expected.sha256 else { throw NativeRuntimeError(message: "Signed compiler input differs from its manifest") }
            try write(bytes, game.appendingPathComponent(relative), mode: 0o755)
        }
        try write(vanilla, game.appendingPathComponent("r6/cache/final.redscripts"))
        let script = "public class NCCUpgradeFixture extends IScriptable { public func Value() -> Int32 { return 1; } }\n"
        try write(Data(script.utf8), game.appendingPathComponent("r6/scripts/UpgradeFixture/Fixture.reds"))
        try FileManager.default.createDirectory(at: game.appendingPathComponent("red4ext/plugins/NightCityRuntime/scripts"), withIntermediateDirectories: true)
        let environment = try NativeRuntimeLaunch.cleanEnvironment(ProcessInfo.processInfo.environment)
        let legacy = try NativeRuntimeLaunch.run(executable: game.appendingPathComponent("engine/tools/scc"), arguments: ["-compile", game.appendingPathComponent("r6/scripts").path], directory: game, environment: environment)
        try check(legacy.contains("Output successfully saved"), "Real legacy compilation failed")
        let original = game.appendingPathComponent("r6/cache/final.redscripts")
        let backup = game.appendingPathComponent("r6/cache/final.redscripts.bk")
        try check(try NativeRuntimeFiles.read(original).map(NativeRuntimeFiles.hash) != NativeScriptCacheUpgrade.vanillaSHA256, "Legacy fixture did not overwrite the original cache")
        try check(try NativeRuntimeFiles.read(backup).map(NativeRuntimeFiles.hash) == NativeScriptCacheUpgrade.vanillaSHA256, "Legacy fixture did not retain its vanilla backup")
        try NativeRuntimeLaunch.compile(gameRoot: game, resources: resources, inherited: ProcessInfo.processInfo.environment)
        try check(try NativeRuntimeFiles.read(original).map(NativeRuntimeFiles.hash) == NativeScriptCacheUpgrade.vanillaSHA256, "First native compile did not restore exact vanilla bytes")
        try check(try NativeRuntimeFiles.read(game.appendingPathComponent(NativeRuntimeManifest.cachePath)) != nil, "First native compile did not publish native output")
        try NativeRuntimeLaunch.compile(gameRoot: game, resources: resources, inherited: ProcessInfo.processInfo.environment)
        try check(try NativeRuntimeFiles.read(original).map(NativeRuntimeFiles.hash) == NativeScriptCacheUpgrade.vanillaSHA256, "Second native compile changed the original")

        let sidecar = game.appendingPathComponent("r6/scripts/UpgradeFixture/._Fixture.reds")
        try write(appleDouble(), sidecar)
        try refuses("Could not load script sources") {
            _ = try NativeRuntimeLaunch.run(executable: game.appendingPathComponent("engine/tools/scc"),
                arguments: ["-compile", game.appendingPathComponent("r6/scripts").path, "-outputCacheFile", game.appendingPathComponent(NativeRuntimeManifest.cachePath).path],
                directory: game, environment: environment)
        }
        try NativeRuntimeLaunch.compile(gameRoot: game, resources: resources, inherited: ProcessInfo.processInfo.environment)
        try check(!FileManager.default.fileExists(atPath: sidecar.path), "Native compile did not remove the recognized AppleDouble script sidecar")
        try check(try NativeRuntimeFiles.read(game.appendingPathComponent("r6/scripts/UpgradeFixture/Fixture.reds")) == Data(script.utf8), "Metadata cleanup changed the primary script")
        try check(try NativeRuntimeFiles.read(vanillaCache) == vanilla, "Read-only source cache changed")
        print("Real signed SCC: legacy compile -> first native restoration -> repeat native compile passed")
        print("Real signed SCC: reproduced 'Could not load script sources' with binary AppleDouble; native cleanup and recompile passed")
    }
}
