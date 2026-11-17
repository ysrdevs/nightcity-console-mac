import Foundation

@main struct NativeModProfilesTests {
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool) throws {
        count += 1; if try !condition() { throw NativeRuntimeError(message: "Profile check failed") }
    }
    static func refuses(_ text: String, _ operation: () throws -> Void) throws {
        count += 1; do { try operation() } catch { if error.localizedDescription.localizedCaseInsensitiveContains(text) { return }; throw error }
        throw NativeRuntimeError(message: "Expected profile refusal: " + text)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nightcity-profile-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try NativeModProfiles.save(name: "  Core  only ", root: root, gameClosed: { true })
        let empty = try NativeModProfiles.read(root)[0]
        try check(empty.name == "Core only")
        try NativeModProfiles.apply(empty, root: root, gameClosed: { true }, validateScripts: {})
        try check(NativeModPackages.readSelection(root)?.packages.isEmpty == true)
        try refuses("already exists") { try NativeModProfiles.save(name: "CORE ONLY", root: root, gameClosed: { true }) }
        try refuses("profile name") { try NativeModProfiles.save(name: "../bad", root: root, gameClosed: { true }) }
        try refuses("profile name") { _ = try NativeModProfiles.normalized(String(repeating: "a", count: 81)) }
        try refuses("Close the game") { try NativeModProfiles.save(name: "Other", root: root, gameClosed: { false }) }
        let workspace = NativeModPackages.base + "/imports/test/nativeSettings", text = Data("fixture ns".utf8), digest = NativeRuntimeFiles.hash(text)
        try NativeRuntimeFiles.write(text, to: root.appendingPathComponent(workspace + "/module.ncclua"))
        let artifact = NativeModPackages.Artifact(source: "module.ncclua", destination: NativeModPackages.release + "/packages/nativeSettings/module.ncclua", size: Int64(text.count), sha256: digest, mode: 0o600)
        let preview = NativeModPackages.Preview(schema: 2, packageId: "nativeSettings", version: "fixture", profileId: "fixture", sourcePath: "/fixture", inventorySHA256: digest, dependencies: [], mutablePolicy: "shared", blockers: [], preparationReady: true)
        let package = NativeModPackages.Package(preview: preview, previewSHA256: digest, workspace: workspace, artifactManifestSHA256: digest, artifacts: [artifact], companionPreviewSHA256: nil)
        let metadata = root.appendingPathComponent("metadata"); try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try NativeModPackages.activate([package], current: NativeModPackages.readSelection(root), root: root, workspace: metadata, gameClosed: { true }, validateScripts: {})
        try NativeModProfiles.save(name: "My Mods", root: root, gameClosed: { true })
        let mods = try NativeModProfiles.read(root).first { $0.name == "My Mods" }!
        let settings = root.appendingPathComponent("red4ext/nightcity-native20/module-data/player.json")
        try NativeRuntimeFiles.write(Data("shared mutable settings".utf8), to: settings)
        try NativeModProfiles.apply(empty, root: root, gameClosed: { true }, validateScripts: {})
        try check(NativeModPackages.readSelection(root)?.packages.isEmpty == true)
        try check(NativeModFiles.identity(root.appendingPathComponent(artifact.destination)) == nil)
        try NativeModProfiles.apply(mods, root: root, gameClosed: { true }, validateScripts: {})
        try check(NativeModPackages.readSelection(root)?.packages.count == 1)
        try check(NativeRuntimeFiles.read(settings) == Data("shared mutable settings".utf8))
        try NativeRuntimeFiles.write(Data("externally edited".utf8), to: root.appendingPathComponent(artifact.destination))
        try refuses("edited") { try NativeModProfiles.apply(empty, root: root, gameClosed: { true }, validateScripts: {}) }
        try check(NativeModPackages.readSelection(root)?.revision == mods.revision)
        try NativeRuntimeFiles.write(text, to: root.appendingPathComponent(artifact.destination))
        try refuses("compiler") { try NativeModProfiles.apply(empty, root: root, gameClosed: { true }, validateScripts: { throw NativeRuntimeError(message: "compiler failed") }) }
        try check(NativeModPackages.readSelection(root)?.revision == mods.revision)
        try check(NativeModFiles.identity(root.appendingPathComponent(artifact.destination))?.sha256 == digest)
        try NativeModProfiles.delete(mods.id, root: root, gameClosed: { true })
        try refuses("changed") { try NativeModProfiles.apply(mods, root: root, gameClosed: { true }, validateScripts: {}) }
        try check(NativeModProfiles.read(root).count == 1)
        let revision = root.appendingPathComponent(NativeModPackages.base + "/revisions/" + empty.revision + ".json")
        try NativeRuntimeFiles.write(Data("[{}]".utf8), to: revision)
        count += 1
        do { try NativeModProfiles.apply(empty, root: root, gameClosed: { true }, validateScripts: {}); throw NativeRuntimeError(message: "Tampered revision accepted") } catch is DecodingError {}
        try check(NativeModPackages.readSelection(root)?.revision == mods.revision)
        print("Native named-profile tests passed: \(count) checks (temporary fixtures only).")
    }
}
