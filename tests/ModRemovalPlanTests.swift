import Foundation
import Darwin

@main
struct ModRemovalPlanTests {
    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("nightcity-removal-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var count = 0
        func check(_ value: Bool) { precondition(value) }
        func write(_ path: URL, _ bytes: Data = Data("keep".utf8)) throws {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: path)
        }
        func run(_ name: String, _ body: (URL, URL) throws -> Void) throws {
            let root = scratch.appendingPathComponent(name + "/game")
            let receipt = root.appendingPathComponent("red4ext/nightcity/mods/test.json")
            try write(receipt, Data("{\"files\":[]}".utf8))
            try body(root, receipt); count += 1; print("PASS \(name)")
        }
        func receipt(_ url: URL, _ paths: [String]) throws { try write(url, JSONSerialization.data(withJSONObject: ["files": paths])) }
        func refused(_ root: URL, _ manifest: URL) {
            do { _ = try ModRemovalPlan.validatedFiles(manifest: manifest, gameRoot: root); preconditionFailure("Unsafe plan accepted") }
            catch { }
        }
        try run("valid-files-missing-and-duplicates") { root, manifest in
            let paths = ["r6/scripts/Example/main.reds", "archive/Mac/mod/Example.archive", "red4ext/plugins/ArchiveXL/Bundle/Example.archive.xl", "red4ext/plugins/Example/config.ini"]
            for path in paths { try write(root.appendingPathComponent(path)) }
            try receipt(manifest, (paths + [paths[0], "r6/scripts/Example/missing.reds"]).map { root.appendingPathComponent($0).path })
            let files = try ModRemovalPlan.validatedFiles(manifest: manifest, gameRoot: root)
            precondition(files.count == 4 && files.allSatisfy { fm.fileExists(atPath: $0.path) })
        }
        try run("foreign-late-entry-rejects-whole-plan") { root, manifest in
            let own = root.appendingPathComponent("r6/scripts/own.reds"), other = scratch.appendingPathComponent("original/r6/scripts/old.reds")
            try write(own); try write(other); try receipt(manifest, [own.path, other.path]); refused(root, manifest)
            check(try Data(contentsOf: own) == Data("keep".utf8)); check(try Data(contentsOf: other) == Data("keep".utf8))
        }
        try run("foreign-receipt") { root, _ in
            let other = scratch.appendingPathComponent("foreign/red4ext/nightcity/mods/test.json")
            try receipt(other, []); refused(root, other)
        }
        try run("receipt-symlink") { root, manifest in
            let target = scratch.appendingPathComponent("receipt-target.json"); try receipt(target, [])
            try fm.removeItem(at: manifest); try fm.createSymbolicLink(at: manifest, withDestinationURL: target); refused(root, manifest)
        }
        try run("receipt-ancestor-symlink") { root, manifest in
            let mods = manifest.deletingLastPathComponent(), target = scratch.appendingPathComponent("receipt-dir")
            try fm.moveItem(at: mods, to: target); try fm.createSymbolicLink(at: mods, withDestinationURL: target); refused(root, manifest)
        }
        for dangling in [false, true] {
            try run("payload-symlink-\(dangling)") { root, manifest in
                let path = root.appendingPathComponent("r6/scripts/example.reds"), target = scratch.appendingPathComponent("target-\(dangling).reds")
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !dangling { try write(target) }
                try fm.createSymbolicLink(at: path, withDestinationURL: target); try receipt(manifest, [path.path]); refused(root, manifest)
            }
        }
        try run("payload-ancestor-symlink") { root, manifest in
            let target = scratch.appendingPathComponent("external-scripts"); try write(target.appendingPathComponent("main.reds"))
            try fm.createDirectory(at: root.appendingPathComponent("r6"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: root.appendingPathComponent("r6/scripts"), withDestinationURL: target)
            try receipt(manifest, [root.appendingPathComponent("r6/scripts/main.reds").path]); refused(root, manifest)
        }
        try run("special-file-and-directory") { root, manifest in
            let path = root.appendingPathComponent("r6/scripts/fifo.reds")
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            precondition(mkfifo(path.path, 0o600) == 0); try receipt(manifest, [path.path]); refused(root, manifest)
            try fm.removeItem(at: path); try fm.createDirectory(at: path, withIntermediateDirectories: false); refused(root, manifest)
        }
        try run("protected-paths-even-when-missing") { root, manifest in
            for path in ["Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077", "r6/cache/final.redscripts", "saves/test.dat", "red4ext/RED4ext.dylib", "red4ext/plugins/Codeware/config.json", "r6/scripts/Codeware.Global.reds", "r6/scripts/zz_nightcity_plugins/anything.reds", "r6/scripts/Renamed/NCCCollisionFlightProbe.reds", "archive/Mac/mod/ModSettings.archive", "red4ext/plugins/ArchiveXL/Bundle/ArchiveXL.archive.xl", "r6/tweaks/cybermodman_user.yaml"] {
                try receipt(manifest, [root.appendingPathComponent(path).path]); refused(root, manifest)
            }
        }
        try run("managed-native-and-exploration-manifests") { root, manifest in
            let managed = "plugins/ArchiveXL/Bundle/Managed.xl"
            try write(root.appendingPathComponent("red4ext/nightcity-native25.txt"), Data((String(repeating: "a", count: 64) + "  " + managed + "\n").utf8))
            try receipt(manifest, [root.appendingPathComponent("red4ext/" + managed).path]); refused(root, manifest)
            try write(root.appendingPathComponent("red4ext/nightcity-exploration.json"), JSONSerialization.data(withJSONObject: ["schema": 1, "files": ["Future.reds": String(repeating: "b", count: 64)]]))
            try receipt(manifest, [root.appendingPathComponent("r6/scripts/NightCityExploration/Future.reds").path]); refused(root, manifest)
        }
        try run("unsafe-managed-manifest") { root, manifest in
            let path = root.appendingPathComponent("r6/scripts/main.reds"); try write(path); try receipt(manifest, [path.path])
            try write(root.appendingPathComponent("red4ext/nightcity-native25.txt"), Data("bad manifest".utf8)); refused(root, manifest)
        }
        try run("absolute-and-traversal-required") { root, manifest in
            try receipt(manifest, ["r6/scripts/a.reds"]); refused(root, manifest)
            try receipt(manifest, [root.path + "/r6/scripts/../scripts/a.reds"]); refused(root, manifest)
        }
        try run("root-system-alias-and-case") { root, manifest in
            let path = root.appendingPathComponent("r6/scripts/main.reds"); try write(path)
            let alias = root.deletingLastPathComponent().appendingPathComponent("GAME")
            if fm.fileExists(atPath: alias.path) {
                try receipt(manifest, [alias.appendingPathComponent("r6/scripts/main.reds").path])
                check(try ModRemovalPlan.validatedFiles(manifest: manifest, gameRoot: root).count == 1)
            }
            let link = scratch.appendingPathComponent("selected-root-alias")
            try fm.createSymbolicLink(at: link, withDestinationURL: root)
            try receipt(manifest, [path.path])
            check(try ModRemovalPlan.validatedFiles(manifest: link.appendingPathComponent("red4ext/nightcity/mods/test.json"), gameRoot: link).count == 1)
        }
        print("\(count) removal checks passed")
    }
}
