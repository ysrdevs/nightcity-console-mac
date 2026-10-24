import Foundation

@main
struct PluginScriptStagerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nightcity-script-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var passed = 0
        func check(_ value: Bool) { precondition(value) }
        func run(_ name: String, _ test: (URL) throws -> Void) throws {
            let dir = root.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try test(dir); passed += 1
            print("PASS \(name)")
        }
        func write(_ path: URL, _ text: String) throws {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
        }
        func read(_ path: URL) throws -> String { try String(contentsOf: path, encoding: .utf8) }
        func stage(_ root: URL, accepted: Bool = true) throws {
            let source = ["TweakXL": root.appendingPathComponent("source")]
            try PluginScriptStager.reconcile(accepted: accepted ? source : [:], knownSources: source,
                scriptsRoot: root.appendingPathComponent("scripts"), manifestURL: root.appendingPathComponent("ownership.json"))
        }
        func expectConflict(_ block: () throws -> Void) throws {
            do { try block(); fatalError("Expected preservation conflict") }
            catch is PluginScriptStager.Conflict { }
        }
        try run("migrate-identical-legacy-and-idempotent") { dir in
            let file = dir.appendingPathComponent("scripts/zz_nightcity_plugins/TweakXL/Module.reds")
            try write(dir.appendingPathComponent("source/Module.reds"), "current")
            try write(dir.appendingPathComponent("scripts/TweakXL/Module.reds"), "current")
            try write(file, "current")
            try write(dir.appendingPathComponent("scripts/Codeware/Private.reds"), "private codeware")
            try write(dir.appendingPathComponent("scripts/VirtualAtelier/Shop.reds"), "private shop")
            let before = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            try stage(dir); try stage(dir)
            check(!fm.fileExists(atPath: dir.appendingPathComponent("scripts/TweakXL/Module.reds").path))
            check(try read(file) == "current")
            check(try read(dir.appendingPathComponent("scripts/Codeware/Private.reds")) == "private codeware")
            check(try read(dir.appendingPathComponent("scripts/VirtualAtelier/Shop.reds")) == "private shop")
            let after = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            check(before == after)
        }
        try run("upgrade-owned-and-remove-dropped-script") { dir in
            try write(dir.appendingPathComponent("source/Module.reds"), "old")
            try write(dir.appendingPathComponent("source/Dropped.reds"), "obsolete")
            try stage(dir)
            try write(dir.appendingPathComponent("source/Module.reds"), "new")
            try fm.removeItem(at: dir.appendingPathComponent("source/Dropped.reds"))
            try stage(dir)
            check(try read(dir.appendingPathComponent("scripts/zz_nightcity_plugins/TweakXL/Module.reds")) == "new")
            check(!fm.fileExists(atPath: dir.appendingPathComponent("scripts/zz_nightcity_plugins/TweakXL/Dropped.reds").path))
        }
        try run("preserve-edited-stage-before-any-mutation") { dir in
            try write(dir.appendingPathComponent("source/Module.reds"), "current")
            try stage(dir)
            try write(dir.appendingPathComponent("scripts/zz_nightcity_plugins/TweakXL/Module.reds"), "user edit")
            try write(dir.appendingPathComponent("scripts/TweakXL/Module.reds"), "current")
            let manifest = try Data(contentsOf: dir.appendingPathComponent("ownership.json"))
            try expectConflict { try stage(dir) }
            check(try read(dir.appendingPathComponent("scripts/zz_nightcity_plugins/TweakXL/Module.reds")) == "user edit")
            check(try read(dir.appendingPathComponent("scripts/TweakXL/Module.reds")) == "current")
            check(try Data(contentsOf: dir.appendingPathComponent("ownership.json")) == manifest)
        }
        try run("preserve-older-legacy") { dir in
            try write(dir.appendingPathComponent("source/Module.reds"), "current")
            try write(dir.appendingPathComponent("scripts/TweakXL/Module.reds"), "older")
            try expectConflict { try stage(dir) }
            check(try read(dir.appendingPathComponent("scripts/TweakXL/Module.reds")) == "older")
            check(!fm.fileExists(atPath: dir.appendingPathComponent("ownership.json").path))
        }
        try run("remove-only-identified-stage-on-version-change") { dir in
            try write(dir.appendingPathComponent("source/Module.reds"), "current")
            try stage(dir)
            try write(dir.appendingPathComponent("scripts/Codeware/Private.reds"), "untouched")
            try stage(dir, accepted: false)
            check(!fm.fileExists(atPath: dir.appendingPathComponent("scripts/zz_nightcity_plugins/TweakXL/Module.reds").path))
            check(try read(dir.appendingPathComponent("scripts/Codeware/Private.reds")) == "untouched")
        }
        try run("preserve-unknown-stage-on-version-change") { dir in
            try write(dir.appendingPathComponent("scripts/zz_nightcity_plugins/Custom/User.reds"), "untouched")
            try expectConflict { try stage(dir, accepted: false) }
            check(try read(dir.appendingPathComponent("scripts/zz_nightcity_plugins/Custom/User.reds")) == "untouched")
        }
        print("\(passed) real filesystem staging checks passed")
    }
}
