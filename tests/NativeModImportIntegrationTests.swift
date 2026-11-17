import Foundation
import Darwin

// Opt-in test against caller-supplied original downloads and a staged app
// Resources tree. The only publication target is this newly-created fixture.
@main struct NativeModImportIntegrationTests {
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else { throw NativeRuntimeError(message: "Usage: test RESOURCES ORIGINAL_PACKAGE...") }
        guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NativeRuntimeError(message: "Cannot resolve temporary directory") }
        defer { free(temporary) }
        let root = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent("nightcity-original-import-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let sources = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
        try NativeRuntimeFiles.write(Data("existing player settings".utf8), to: root.appendingPathComponent("red4ext/nightcity-native20/module-data/immersive_third_person/config.json"))
        guard let review = try NativeModPackages.prepare(sources: sources, gameRoot: root, resources: resources, gameClosed: { true }) else { throw NativeRuntimeError(message: "Expected recognized original packages") }
        try NativeRuntimeFiles.require(try NativeModPackages.readSelection(root) == nil, "Preview published a selection")
        var compiled = 0
        try NativeModPackages.apply(review, gameClosed: { true }, validateScripts: {
            // The actual game compiler is intentionally not invoked by this
            // fixture. Verify every staged artifact before metadata commits.
            for package in review.selected { for file in package.artifacts {
                try NativeRuntimeFiles.require(try NativeModFiles.identity(root.appendingPathComponent(file.destination)) == .init(sha256: file.sha256, size: file.size), "Staged file differs")
            } }
            try NativeRuntimeFiles.require(try NativeModPackages.readSelection(root) == nil, "Selection published before compile validation")
            compiled += 1
        })
        try NativeRuntimeFiles.require(compiled == 1, "Expected one complete validation batch")
        let selection = try NativeModPackages.readSelection(root)!
        try NativeRuntimeFiles.require(selection.packages.count == sources.count, "Missing original package")
        try NativeModPackages.restorePrevious(gameRoot: root, gameClosed: { true }, validateScripts: {})
        try NativeRuntimeFiles.require(try NativeModPackages.readSelection(root)?.packages.isEmpty == true, "Restore did not select the original empty revision")
        for package in review.selected { for file in package.artifacts {
            try NativeRuntimeFiles.require(try NativeModFiles.identity(root.appendingPathComponent(file.destination)) == nil, "Restore left a selected artifact")
        } }
        let settings = try NativeRuntimeFiles.read(root.appendingPathComponent("red4ext/nightcity-native20/module-data/immersive_third_person/config.json"))
        try NativeRuntimeFiles.require(settings == Data("existing player settings".utf8), "Settings changed")
        let result: [String: Any] = ["passed": true, "packageCount": selection.packages.count, "artifactCount": selection.packages.reduce(0) { $0 + $1.artifacts.count },
            "scope": "Actual self-contained helper and original packages through production Swift preview/apply/restore; temporary fixture only, no game compiler or runtime admission."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
