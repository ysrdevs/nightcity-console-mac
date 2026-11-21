import Foundation
import Darwin

// Byte-migration integration test. All runtime payload bytes come from actual
// releases; only the game identity is replaced by a minimal non-executable
// Mach-O fixture. No game or payload code is launched.
@main struct NativeRuntimeUpgradeTests {
    struct LegacyFile: Codable { let path: String; let sha256: String; let size: Int }
    struct LegacyInventory: Codable {
        let version: String; let archive: String; let archiveSHA256: String; let files: [LegacyFile]
    }
    static var checks = 0
    static let fm = FileManager.default
    static let compilerPaths = ["engine/tools/scc", "engine/tools/libscc_lib.dylib"]
    static let userFiles: [String: Data] = [
        "red4ext/cybermodman_names.json": Data("{\"7777798\":\"Player weapon\"}".utf8),
        "r6/tweaks/cybermodman_PlayerWeapon.yaml": Data("Items.PlayerWeapon:\n  $base: Items.Preset_Ajax_Default\n".utf8),
        "r6/scripts/PlayerMod/custom.reds": Data("// Player's unrelated mod\n".utf8),
        "archive/Mac/mod/PlayerMod.archive": Data("unchanged player archive".utf8),
        "red4ext/plugins/ModSettings/settings.json": Data("{\"playerSetting\":7}".utf8),
        "red4ext/nightcity-native20/module-data/immersive_third_person/settings.lua": Data("return {nativeToggleKey='IK_F10'}\n".utf8),
        "red4ext/nightcity/mods/PlayerMod.json": Data("{\"name\":\"PlayerMod\",\"files\":[]}".utf8)
    ]

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw NativeRuntimeError(message: message) }
    }
    static func refuses(_ expected: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch {
            try check(error.localizedDescription.contains(expected), "Unexpected refusal: \(error.localizedDescription); wanted \(expected)")
            return
        }
        throw NativeRuntimeError(message: "Expected refusal: \(expected)")
    }
    static func read(_ root: URL, _ path: String) throws -> Data? {
        try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, path))
    }
    static func copy(_ source: URL, _ destination: URL) throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
    }
    static func gameImage() -> Data {
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
    static func stagedManifest(_ original: NativeRuntimeManifest, omitCompilerHistory: Bool) throws -> NativeRuntimeManifest {
        let identity = try NativeRuntimeManifest.imageIdentity(gameImage())
        var previous = original.previousFiles
        if omitCompilerHistory { for path in compilerPaths { previous.removeValue(forKey: path) } }
        return .init(schema: original.schema, backend: original.backend, gameVersion: original.gameVersion,
            executable: .init(relativePath: original.executable.relativePath, uuid: identity.uuid, textSHA256: identity.textSHA256),
            files: original.files, injectedDylibs: original.injectedDylibs, scriptRoots: original.scriptRoots,
            environment: original.environment, previousFiles: previous, retiredFiles: original.retiredFiles,
            requiresPreparedPackages: original.requiresPreparedPackages)
    }
    struct Fixture {
        let game: URL
        init(parent: URL, name: String, legacy: URL, inventory: LegacyInventory) throws {
            game = parent.appendingPathComponent(name)
            for file in inventory.files {
                try copy(try NativeRuntimeFiles.checked(legacy, file.path), try NativeRuntimeFiles.checked(game, file.path))
            }
            try NativeRuntimeFiles.write(gameImage(), to: game.appendingPathComponent("Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"))
            for (path, bytes) in userFiles { try NativeRuntimeFiles.write(bytes, to: game.appendingPathComponent(path)) }
        }
        func verifyUsers() throws {
            for (path, bytes) in userFiles { try check(read(game, path) == bytes, "Player data changed: \(path)") }
        }
        func verifyOriginal(_ inventory: LegacyInventory, candidate: NativeRuntimeManifest) throws {
            for file in inventory.files {
                try check(read(game, file.path).map(NativeRuntimeFiles.hash) == file.sha256, "Legacy file not preserved/restored: \(file.path)")
            }
            let old = Set(inventory.files.map(\.path))
            for file in candidate.files where !old.contains(file.path) {
                try check(read(game, file.path) == nil, "New runtime file survived rollback: \(file.path)")
            }
            try check(read(game, NativeRuntimeInstallation.receiptPath) == nil, "Unexpected native receipt")
            try check(read(game, NativeRuntimeInstallation.pendingPath) == nil, "Pending journal survived completed recovery")
            try verifyUsers()
        }
    }
    static func journal(_ fixture: Fixture) throws -> NativeRuntimeInstallation.Journal {
        guard let bytes = try read(fixture.game, NativeRuntimeInstallation.pendingPath) else { throw NativeRuntimeError(message: "Missing installation journal during apply") }
        return try JSONDecoder().decode(NativeRuntimeInstallation.Journal.self, from: bytes)
    }
    static func verifyBackups(_ value: NativeRuntimeInstallation.Journal, fixture: Fixture, inventory: LegacyInventory, candidate: NativeRuntimeManifest) throws {
        let old = Dictionary(uniqueKeysWithValues: inventory.files.map { ($0.path, $0.sha256) })
        let desired = Dictionary(uniqueKeysWithValues: candidate.files.map { ($0.path, $0.sha256) })
        for file in inventory.files where desired[file.path] != file.sha256 {
            let entries = value.changes.filter { $0.path == file.path }
            try check(entries.count == 1 && entries.first?.before == file.sha256,
                "Changed legacy file missing from backup journal: \(file.path)")
        }
        for change in value.changes {
            if let before = change.before {
                try check(old[change.path] == before, "Journal changed an unowned legacy path: \(change.path)")
                guard let backup = change.backup else { throw NativeRuntimeError(message: "Missing exact backup: \(change.path)") }
                try check(read(fixture.game, backup).map(NativeRuntimeFiles.hash) == before, "Backup differs from published legacy bytes: \(change.path)")
            } else { try check(change.backup == nil, "Unexpected backup of absent path") }
        }
    }
    static func main() {
        do { try run() }
        catch {
            fputs("Upgrade integration failed: \(error.localizedDescription)\n", stderr)
            if CommandLine.arguments.count == 5 {
                let destination = URL(fileURLWithPath: CommandLine.arguments[4])
                let failure: [String: Any] = ["passed": false, "error": error.localizedDescription, "checks": checks, "gameLaunched": false]
                try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let bytes = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys]) {
                    try? bytes.write(to: destination, options: .atomic)
                }
            }
            exit(1)
        }
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { throw NativeRuntimeError(message: "Usage: native-runtime-upgrade-tests STAGED_LEGACY INVENTORY CANDIDATE_RESOURCES RESULT_JSON") }
        let legacy = URL(fileURLWithPath: args[1]), inventoryURL = URL(fileURLWithPath: args[2])
        let candidateResources = URL(fileURLWithPath: args[3]), resultURL = URL(fileURLWithPath: args[4])
        let inventory = try JSONDecoder().decode(LegacyInventory.self, from: Data(contentsOf: inventoryURL))
        let (candidate, candidateDigest) = try NativeRuntimeManifest.load(resources: candidateResources)
        try check(!inventory.files.isEmpty && Set(inventory.files.map(\.path)).count == inventory.files.count, "Invalid published legacy inventory")
        let desired = Dictionary(uniqueKeysWithValues: candidate.files.map { ($0.path, $0.sha256) })
        for file in inventory.files {
            try check(NativeRuntimeManifest.managedPath(file.path), "Inventory includes a non-runtime path: \(file.path)")
            guard let bytes = try read(legacy, file.path) else { throw NativeRuntimeError(message: "Missing actual legacy file: \(file.path)") }
            try check(bytes.count == file.size && NativeRuntimeFiles.hash(bytes) == file.sha256, "Legacy release bytes do not match inventory: \(file.path)")
            try check(desired[file.path] != nil || candidate.retiredFiles[file.path] != nil, "Legacy runtime file is neither retained nor retired: \(file.path)")
        }
        for path in compilerPaths {
            guard let old = inventory.files.first(where: { $0.path == path }) else { throw NativeRuntimeError(message: "Legacy compiler absent: \(path)") }
            try check(desired[path] != old.sha256, "Regression requires actual old/new compiler bytes to differ: \(path)")
        }

        let parent = fm.temporaryDirectory.appendingPathComponent("nightcity-release-upgrade-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let resources = parent.appendingPathComponent("candidate-resources")
        // Copy only the exact managed candidate payload, not a game installation.
        for file in candidate.files {
            let relative = "native20/payload/" + file.path
            try copy(try NativeRuntimeFiles.checked(candidateResources, relative), try NativeRuntimeFiles.checked(resources, relative))
        }
        let staged = try stagedManifest(candidate, omitCompilerHistory: false)
        func writeManifest(_ manifest: NativeRuntimeManifest) throws {
            try NativeRuntimeFiles.write(JSONEncoder().encode(manifest), to: resources.appendingPathComponent(NativeRuntimeManifest.manifestRelative))
        }

        // Reproduce the released 2.0 omission. This must refuse at preflight,
        // without a receipt or even one runtime-file apply callback.
        try writeManifest(stagedManifest(candidate, omitCompilerHistory: true))
        let refused = try Fixture(parent: parent, name: "missing-compiler-history", legacy: legacy, inventory: inventory)
        var refusedApplies = 0
        try refuses("engine/tools/libscc_lib.dylib") {
            try NativeRuntimeInstallation.install(gameRoot: refused.game, resources: resources, gameClosed: { true }, didApply: { _ in refusedApplies += 1 })
        }
        try check(refusedApplies == 0, "Rejected compiler history modified runtime files")
        try refused.verifyOriginal(inventory, candidate: candidate)
        try fm.removeItem(at: refused.game)

        // Run the unmodified candidate's history against all published bytes.
        // An old manifest that omits compilers fails here, rather than being
        // silently repaired by the fixture.
        try writeManifest(staged)
        let completed = try Fixture(parent: parent, name: "published-upgrade", legacy: legacy, inventory: inventory)
        var committedJournal: NativeRuntimeInstallation.Journal?
        var completedApplies = 0
        try NativeRuntimeInstallation.install(gameRoot: completed.game, resources: resources, gameClosed: { true }, didApply: { index in
            if index == 0 { committedJournal = try journal(completed) }
            completedApplies += 1
        })
        guard let committedJournal else { throw NativeRuntimeError(message: "Upgrade applied no changes") }
        try check(completedApplies == committedJournal.changes.count, "Upgrade skipped a recorded change")
        try check(NativeRuntimeInstallation.current(gameRoot: completed.game, resources: resources), "Upgrade receipt or payload not current")
        for file in candidate.files { try check(read(completed.game, file.path).map(NativeRuntimeFiles.hash) == file.sha256, "Candidate file differs after upgrade: \(file.path)") }
        for file in inventory.files where desired[file.path] == nil { try check(read(completed.game, file.path) == nil, "Retired legacy runtime still exists: \(file.path)") }
        try completed.verifyUsers()
        try verifyBackups(committedJournal, fixture: completed, inventory: inventory, candidate: candidate)
        try check(read(completed.game, NativeRuntimeInstallation.pendingPath) == nil, "Successful upgrade left a pending journal")
        try fm.removeItem(at: completed.game)

        // Match the reported player workaround: both compiler files were
        // deleted, while the rest of the published legacy runtime remained.
        let missingCompilers = try Fixture(parent: parent, name: "deleted-compilers", legacy: legacy, inventory: inventory)
        for path in compilerPaths {
            try fm.removeItem(at: NativeRuntimeFiles.checked(missingCompilers.game, path))
            try check(read(missingCompilers.game, path) == nil, "Compiler-deletion fixture is not missing \(path)")
        }
        try NativeRuntimeInstallation.install(gameRoot: missingCompilers.game, resources: resources, gameClosed: { true })
        for path in compilerPaths {
            try check(read(missingCompilers.game, path).map(NativeRuntimeFiles.hash) == desired[path], "Deleted compiler was not restored: \(path)")
        }
        try check(NativeRuntimeInstallation.current(gameRoot: missingCompilers.game, resources: resources), "Compiler repair left an incomplete runtime")
        for file in inventory.files where desired[file.path] == nil {
            try check(read(missingCompilers.game, file.path) == nil, "Compiler repair left a retired runtime file: \(file.path)")
        }
        try check(read(missingCompilers.game, NativeRuntimeInstallation.pendingPath) == nil, "Compiler repair left a pending journal")
        try missingCompilers.verifyUsers()
        try fm.removeItem(at: missingCompilers.game)

        // Interrupt after the final receipt write. Recovery must undo every
        // replacement, deletion and new file, including the receipt itself.
        let interrupted = try Fixture(parent: parent, name: "interrupted-upgrade", legacy: legacy, inventory: inventory)
        var interruptedJournal: NativeRuntimeInstallation.Journal?
        var interruptedApplies = 0
        try refuses("injected final-write interruption") {
            try NativeRuntimeInstallation.install(gameRoot: interrupted.game, resources: resources, gameClosed: { true }, didApply: { index in
                if index == 0 { interruptedJournal = try journal(interrupted) }
                interruptedApplies += 1
                if let value = interruptedJournal, index == value.changes.count - 1 {
                    throw NativeRuntimeError(message: "injected final-write interruption")
                }
            })
        }
        guard let interruptedJournal else { throw NativeRuntimeError(message: "Interruption never reached apply") }
        try check(interruptedApplies == interruptedJournal.changes.count, "Did not exercise final-write rollback")
        try interrupted.verifyOriginal(inventory, candidate: candidate)
        try verifyBackups(interruptedJournal, fixture: interrupted, inventory: inventory, candidate: candidate)
        try check(!NativeRuntimeInstallation.current(gameRoot: interrupted.game, resources: resources), "Rolled-back upgrade incorrectly marked current")
        try NativeRuntimeInstallation.install(gameRoot: interrupted.game, resources: resources, gameClosed: { true })
        try check(NativeRuntimeInstallation.current(gameRoot: interrupted.game, resources: resources), "Retry after rollback did not complete")
        try interrupted.verifyUsers()

        let report: [String: Any] = [
            "passed": true, "scope": "Published runtime byte migration; synthetic game identity; no game or payload code executed",
            "legacyVersion": inventory.version, "legacyArchive": inventory.archive, "legacyArchiveSHA256": inventory.archiveSHA256,
            "legacyFiles": inventory.files.count, "candidateResources": candidateResources.path,
            "candidateManifestSHA256": candidateDigest, "candidateFiles": candidate.files.count,
            "omittedCompilerHistoryRefusedBeforeApply": true, "completeUpgradePassed": true,
            "exactLegacyBackupsPassed": true, "userDataPreserved": true, "finalWriteRollbackPassed": true,
            "deletedCompilerRepairPassed": true,
            "retryAfterRollbackPassed": true, "checks": checks, "gameLaunched": false
        ]
        try fm.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL, options: .atomic)
        print("\(checks) published \(inventory.version) upgrade integration checks passed; no game launched")
        print(resultURL.path)
    }
}
