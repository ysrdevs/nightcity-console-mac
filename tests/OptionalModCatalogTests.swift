import Foundation
import CryptoKit

// Standalone filesystem checks; no game, bundle, user defaults or installed app is touched.
// swiftc launcher/Sources/OptionalModCatalog.swift launcher/Sources/ModImportPlan.swift tests/OptionalModCatalogTests.swift -o /tmp/nightcity-optional-mod-tests
@main
struct OptionalModCatalogTests {
    static func main() throws {
        let fm = FileManager.default
        // Use the normal macOS temporary path, including its system /var alias.
        let root = fm.temporaryDirectory.appendingPathComponent("nightcity-optional-mod-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var passed = 0

        func check(_ value: Bool, _ message: String = "Unexpected result") { precondition(value, message) }
        func run(_ name: String, _ body: (URL) throws -> Void) throws {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try body(dir); passed += 1; print("PASS \(name)")
        }
        func write(_ path: URL, _ bytes: Data) throws {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: path)
        }
        func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        func fixture(_ resources: URL, mutate: ((inout [String: Any]) -> Void)? = nil) throws -> URL {
            let catalogRoot = resources.appendingPathComponent("optional-mods", isDirectory: true)
            var mods = [[String: Any]]()
            for (id, version, module) in [("equipment-ex", "1.2.9", "EquipmentEx"), ("cyberware-ex", "1.5.6", "CyberwareEx")] {
                let package = "\(id)-\(version)"
                let scripts = "r6/scripts/\(module)"
                let files = ["\(scripts)/main.reds": Data("module \(module)\n".utf8), "\(scripts)/LICENSE": Data("fixture license \(module)\n".utf8)]
                for (path, bytes) in files { try write(catalogRoot.appendingPathComponent("\(package)/\(path)"), bytes) }
                mods.append(["id": id, "name": id, "version": version, "package": package,
                             "files": files.mapValues(hash), "script_directory": scripts])
            }
            var json: [String: Any] = ["schema": 2, "game_version": "2.5.0", "mods": mods]
            mutate?(&json)
            try write(catalogRoot.appendingPathComponent("manifest.json"), JSONSerialization.data(withJSONObject: json))
            return catalogRoot
        }
        func expectError(_ kind: String, _ body: () throws -> Void) throws {
            do { try body(); preconditionFailure("Expected \(kind)") }
            catch let error as OptionalModError {
                switch (kind, error) {
                case ("missing", .missingCatalog), ("catalog", .invalidCatalog), ("package", .invalidPackage): break
                default: preconditionFailure("Expected \(kind), got \(error)")
                }
            }
        }
        func editFirstMod(_ json: inout [String: Any], _ body: (inout [String: Any]) -> Void) {
            var mods = json["mods"] as! [[String: Any]]; body(&mods[0]); json["mods"] = mods
        }
        func editFiles(_ json: inout [String: Any], _ body: (inout [String: String]) -> Void) {
            editFirstMod(&json) { mod in var files = mod["files"] as! [String: String]; body(&files); mod["files"] = files }
        }
        try run("both-folder-packages-verify") { dir in
            let catalogRoot = try fixture(dir)
            let catalog = try OptionalModCatalog.load(resources: dir)
            check(catalog.mods.count == 2)
            for mod in catalog.mods {
                let verified = try catalog.verifiedPackage(for: mod)
                check(verified == catalogRoot.appendingPathComponent(mod.package, isDirectory: true))
                check(ModImportPlan.manifestBase(for: verified) == mod.package)
            }
        }
        try run("missing-resources-and-manifest") { dir in
            try expectError("missing") { _ = try OptionalModCatalog.load(resources: nil) }
            try expectError("missing") { _ = try OptionalModCatalog.load(resources: dir) }
        }
        try run("malformed-manifest") { dir in
            try write(dir.appendingPathComponent("optional-mods/manifest.json"), Data("{".utf8))
            try expectError("catalog") { _ = try OptionalModCatalog.load(resources: dir) }
        }
        for (name, edit) in [
            ("wrong-schema", { (json: inout [String: Any]) in json["schema"] = 1 }),
            ("wrong-game", { (json: inout [String: Any]) in json["game_version"] = "2.3.1" }),
            ("missing-mod", { (json: inout [String: Any]) in json["mods"] = Array((json["mods"] as! [[String: Any]]).prefix(1)) }),
            ("duplicate-mod", { (json: inout [String: Any]) in var mods = json["mods"] as! [[String: Any]]; mods.append(mods[0]); json["mods"] = mods }),
            ("unknown-mod", { (json: inout [String: Any]) in editFirstMod(&json) { $0["id"] = "unknown" } }),
            ("wrong-script-directory", { (json: inout [String: Any]) in editFirstMod(&json) { $0["script_directory"] = "../r6/scripts/EquipmentEx" } }),
            ("old-zip-package-name", { (json: inout [String: Any]) in editFirstMod(&json) { $0["package"] = "equipment-ex-1.2.9.zip" } }),
            ("parent-package-path", { (json: inout [String: Any]) in editFirstMod(&json) { $0["version"] = "../../other"; $0["package"] = "equipment-ex-../../other" } }),
            ("backslash-package-path", { (json: inout [String: Any]) in editFirstMod(&json) { $0["package"] = "..\\other" } }),
            ("empty-name", { (json: inout [String: Any]) in editFirstMod(&json) { $0["name"] = "" } }),
            ("control-name", { (json: inout [String: Any]) in editFirstMod(&json) { $0["name"] = "name\n" } }),
            ("long-name", { (json: inout [String: Any]) in editFirstMod(&json) { $0["name"] = String(repeating: "a", count: 81) } }),
            ("short-hash", { (json: inout [String: Any]) in editFiles(&json) { $0["r6/scripts/EquipmentEx/main.reds"] = "0123" } }),
            ("nonhex-hash", { (json: inout [String: Any]) in editFiles(&json) { $0["r6/scripts/EquipmentEx/main.reds"] = String(repeating: "z", count: 64) } }),
            ("uppercase-hash", { (json: inout [String: Any]) in editFiles(&json) { $0["r6/scripts/EquipmentEx/main.reds"] = String(repeating: "A", count: 64) } }),
            ("no-files", { (json: inout [String: Any]) in editFiles(&json) { $0 = [:] } }),
            ("missing-license", { (json: inout [String: Any]) in editFiles(&json) { $0.removeValue(forKey: "r6/scripts/EquipmentEx/LICENSE") } }),
            ("too-many-files", { (json: inout [String: Any]) in editFiles(&json) { files in for i in 0..<256 { files["r6/scripts/EquipmentEx/\(i).reds"] = String(repeating: "a", count: 64) } } }),
            ("case-alias-path", { (json: inout [String: Any]) in editFiles(&json) { $0["r6/scripts/EquipmentEx/MAIN.reds"] = String(repeating: "a", count: 64) } }),
            ("file-parent-conflict", { (json: inout [String: Any]) in editFiles(&json) { $0["r6/scripts/EquipmentEx"] = String(repeating: "a", count: 64) } })
        ] {
            try run(name) { dir in _ = try fixture(dir, mutate: edit); try expectError("catalog") { _ = try OptionalModCatalog.load(resources: dir) } }
        }
        for path in ["../outside.reds", "/absolute.reds", "r6//file.reds", "r6/./file.reds", "r6/../file.reds", "r6\\file.reds", "r6/bad\n.reds", "r6/colon:file.reds", String(repeating: "a", count: 129), String(repeating: "a/", count: 16) + "a"] {
            try run("unsafe-file-path-\(passed)") { dir in
                _ = try fixture(dir) { editFiles(&$0) { $0[path] = String(repeating: "a", count: 64) } }
                try expectError("catalog") { _ = try OptionalModCatalog.load(resources: dir) }
            }
        }
        try run("oversize-manifest") { dir in
            let catalogRoot = try fixture(dir)
            try write(catalogRoot.appendingPathComponent("manifest.json"), Data(repeating: 32, count: 128 * 1024 + 1))
            try expectError("catalog") { _ = try OptionalModCatalog.load(resources: dir) }
        }
        try run("changed-file-after-load") { dir in
            let catalogRoot = try fixture(dir); let catalog = try OptionalModCatalog.load(resources: dir)
            let mod = catalog.mods[0]
            try write(catalogRoot.appendingPathComponent("\(mod.package)/\(mod.scriptDirectory)/main.reds"), Data("tampered".utf8))
            try expectError("package") { _ = try catalog.verifiedPackage(for: mod) }
            _ = try catalog.verifiedPackage(for: catalog.mods[1])
        }
        try run("nonmember-package") { dir in
            _ = try fixture(dir); let catalog = try OptionalModCatalog.load(resources: dir); let original = catalog.mods[0]
            let changed = OptionalMod(id: original.id, name: original.name, version: original.version, package: "../outside", files: original.files, scriptDirectory: original.scriptDirectory)
            try expectError("catalog") { _ = try catalog.verifiedPackage(for: changed) }
            let changedHash = OptionalMod(id: original.id, name: original.name, version: original.version, package: original.package, files: original.files.mapValues { _ in String(repeating: "0", count: 64) }, scriptDirectory: original.scriptDirectory)
            try expectError("catalog") { _ = try catalog.verifiedPackage(for: changedHash) }
        }
        for variant in ["missing", "regular-file", "symlink", "empty-directory"] {
            try run("package-\(variant)") { dir in
                let catalogRoot = try fixture(dir); let catalog = try OptionalModCatalog.load(resources: dir); let mod = catalog.mods[0]
                let package = catalogRoot.appendingPathComponent(mod.package)
                if variant == "symlink" {
                    let outside = dir.appendingPathComponent("outside"); try fm.moveItem(at: package, to: outside)
                    try fm.createSymbolicLink(at: package, withDestinationURL: outside)
                } else {
                    try fm.removeItem(at: package)
                    if variant == "regular-file" { try write(package, Data("not a folder".utf8)) }
                    if variant == "empty-directory" { try fm.createDirectory(at: package, withIntermediateDirectories: false) }
                }
                try expectError("package") { _ = try catalog.verifiedPackage(for: mod) }
            }
        }
        for variant in ["missing", "empty", "directory", "symlink", "oversize", "extra-file", "extra-hidden-file", "extra-directory", "linked-subdirectory"] {
            try run("payload-\(variant)") { dir in
                let catalogRoot = try fixture(dir); let catalog = try OptionalModCatalog.load(resources: dir); let mod = catalog.mods[0]
                let package = catalogRoot.appendingPathComponent(mod.package)
                let file = package.appendingPathComponent("\(mod.scriptDirectory)/main.reds")
                switch variant {
                case "extra-file": try write(package.appendingPathComponent("unexpected.reds"), Data([1]))
                case "extra-hidden-file": try write(package.appendingPathComponent(".hidden"), Data([1]))
                case "extra-directory": try fm.createDirectory(at: package.appendingPathComponent("unexpected"), withIntermediateDirectories: false)
                case "linked-subdirectory":
                    let original = package.appendingPathComponent(mod.scriptDirectory); let outside = dir.appendingPathComponent("outside")
                    try fm.moveItem(at: original, to: outside); try fm.createSymbolicLink(at: original, withDestinationURL: outside)
                default:
                    try fm.removeItem(at: file)
                    switch variant {
                    case "empty": try write(file, Data())
                    case "directory": try fm.createDirectory(at: file, withIntermediateDirectories: false)
                    case "symlink":
                        let outside = dir.appendingPathComponent("outside.reds"); try write(outside, Data("module EquipmentEx\n".utf8))
                        try fm.createSymbolicLink(at: file, withDestinationURL: outside)
                    case "oversize":
                        check(fm.createFile(atPath: file.path, contents: nil)); let handle = try FileHandle(forWritingTo: file)
                        try handle.truncate(atOffset: 32 * 1024 * 1024 + 1); try handle.close()
                    default: break
                    }
                }
                try expectError("package") { _ = try catalog.verifiedPackage(for: mod) }
            }
        }
        for component in ["manifest", "catalog-root", "resources-root"] {
            try run("linked-\(component)-rejected") { dir in
                let resources = dir.appendingPathComponent("outer/resources")
                let catalogRoot = try fixture(resources)
                let original: URL
                switch component {
                case "manifest": original = catalogRoot.appendingPathComponent("manifest.json")
                case "catalog-root": original = catalogRoot
                default: original = resources
                }
                let outside = dir.appendingPathComponent("moved")
                let catalog = try OptionalModCatalog.load(resources: resources)
                try fm.moveItem(at: original, to: outside); try fm.createSymbolicLink(at: original, withDestinationURL: outside)
                try expectError("catalog") { _ = try OptionalModCatalog.load(resources: resources) }
                if component != "manifest" { try expectError("package") { _ = try catalog.verifiedPackage(for: catalog.mods[0]) } }
            }
        }
        try run("aliases-above-resources-boundary-are-allowed") { dir in
            let original = dir.appendingPathComponent("original")
            let resources = original.appendingPathComponent("resources")
            _ = try fixture(resources)
            let linkedParent = dir.appendingPathComponent("linked-parent")
            try fm.createSymbolicLink(at: linkedParent, withDestinationURL: original)
            let catalog = try OptionalModCatalog.load(resources: linkedParent.appendingPathComponent("resources"))
            for mod in catalog.mods { _ = try catalog.verifiedPackage(for: mod) }
        }
        try run("combined-package-size-is-bounded") { dir in
            let bytes = Data(repeating: 65, count: 17 * 1024 * 1024)
            let catalogRoot = try fixture(dir) { editFiles(&$0) { files in for path in files.keys { files[path] = hash(bytes) } } }
            let catalog = try OptionalModCatalog.load(resources: dir); let mod = catalog.mods[0]
            for path in mod.files.keys { try write(catalogRoot.appendingPathComponent("\(mod.package)/\(path)"), bytes) }
            try expectError("package") { _ = try catalog.verifiedPackage(for: mod) }
        }
        try run("known-zip-and-folder-receipt-display-keeps-version") { _ in
            for package in ["equipment-ex-1.2.9", "cyberware-ex-1.5.6"] {
                // Old ZIPs and new folders use the same explicit filename, regardless of the
                // helper's embedded display name (full for ZIP, last suffix removed for folder).
                check(OptionalModCatalog.installedDisplayName(manifestFilename: package + ".json") == package)
            }
            for name in ["equipment-ex-1.2.json", "cyberware-ex-1.5.json", "other.json", "equipment-ex-1.2.9.zip.json", "../equipment-ex-1.2.9.json"] {
                check(OptionalModCatalog.installedDisplayName(manifestFilename: name) == nil)
            }
        }
        try run("manual-nested-scripts-are-preserved") { dir in
            _ = try fixture(dir)
            let catalog = try OptionalModCatalog.load(resources: dir)
            let game = dir.appendingPathComponent("game", isDirectory: true)
            for mod in catalog.mods {
                let script = game.appendingPathComponent(mod.scriptDirectory).appendingPathComponent("Nested/Custom.REDS")
                let original = Data("player's custom source\n".utf8)
                try write(script, original)
                check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == "Already present. Keep your existing install")
                check(try Data(contentsOf: script) == original)
                check(OptionalModCatalog.installedStatus(mod, gameRoot: game) != nil)
                check(try Data(contentsOf: script) == original)
            }
        }
        try run("empty-and-nonscript-directories-are-not-installed") { dir in
            _ = try fixture(dir)
            let mod = try OptionalModCatalog.load(resources: dir).mods[0]
            let game = dir.appendingPathComponent("game", isDirectory: true)
            check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == nil)
            let scripts = game.appendingPathComponent(mod.scriptDirectory)
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == nil)
            try write(scripts.appendingPathComponent("LICENSE.txt"), Data("license".utf8))
            try fm.createDirectory(at: scripts.appendingPathComponent("misleading.reds"), withIntermediateDirectories: true)
            check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == nil)
        }
        try run("managed-manifest-requires-scripts") { dir in
            _ = try fixture(dir)
            let mod = try OptionalModCatalog.load(resources: dir).mods[0]
            let game = dir.appendingPathComponent("game", isDirectory: true)
            let stem = mod.package
            try write(game.appendingPathComponent("red4ext/nightcity/mods/\(stem).json"), Data("{}".utf8))
            check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == nil)
            let script = game.appendingPathComponent(mod.scriptDirectory).appendingPathComponent("main.reds")
            try write(script, Data("module EquipmentEx".utf8))
            check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == "Installed")
            try fm.removeItem(at: script)
            check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == nil)
        }
        try run("manual-renamed-source-folders-are-preserved") { dir in
            _ = try fixture(dir)
            let catalog = try OptionalModCatalog.load(resources: dir)
            let game = dir.appendingPathComponent("game", isDirectory: true)
            for mod in catalog.mods {
                let module = mod.id == "equipment-ex" ? "EquipmentEx" : "CyberwareEx"
                let script = game.appendingPathComponent("r6/scripts/my-\(mod.id)/src/Core.reds")
                let original = Data("// Custom source layout\r\nmodule \(module)\r\n\r\npublic class UserClass {}\r\n".utf8)
                try write(script, original)
                check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == "Already present. Keep your existing install")
                check(try Data(contentsOf: script) == original)
                check(!fm.fileExists(atPath: game.appendingPathComponent(mod.scriptDirectory).path))
            }
        }
        try run("manual-facade-only-detection") { dir in
            _ = try fixture(dir)
            let catalog = try OptionalModCatalog.load(resources: dir)
            let game = dir.appendingPathComponent("game", isDirectory: true)
            for mod in catalog.mods {
                let module = mod.id == "equipment-ex" ? "EquipmentEx" : "CyberwareEx"
                let script = game.appendingPathComponent("r6/scripts/custom/\(module).Global.reds")
                let original = Data("public abstract class \(module)\n{\n  public static func Version() -> String = \"custom\";\n}\n".utf8)
                try write(script, original)
                check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == "Already present. Keep your existing install")
                check(try Data(contentsOf: script) == original)
            }
        }
        try run("imports-comments-and-other-module-names-are-not-cores") { dir in
            _ = try fixture(dir)
            let catalog = try OptionalModCatalog.load(resources: dir)
            let game = dir.appendingPathComponent("game", isDirectory: true)
            let script = game.appendingPathComponent("r6/scripts/VirtualAtelier/Compatibility.reds")
            let original = Data("""
                module VirtualAtelier
                import EquipmentEx.*
                import CyberwareEx.*
                // module EquipmentEx
                // public abstract class CyberwareEx {
                module EquipmentExtra
                module CyberwareExtra
                public abstract class EquipmentExtra {}
                public abstract class CyberwareExtra {}
                """.utf8)
            try write(script, original)
            for mod in catalog.mods {
                check(OptionalModCatalog.installedStatus(mod, gameRoot: game) == nil)
            }
            check(try Data(contentsOf: script) == original)
        }
        try run("virtual-atelier-existing-archive-is-preserved") { dir in
            let archive = dir.appendingPathComponent("archive/Mac/mod/VirtualAtelier.archive")
            let original = Data("player's VA archive".utf8)
            check(!ModImportPlan.hasVirtualAtelier(in: dir))
            try write(archive, original)
            check(ModImportPlan.hasVirtualAtelier(in: dir))
            check(try Data(contentsOf: archive) == original)
            check(!fm.fileExists(atPath: dir.appendingPathComponent("r6/scripts").path))
        }
        try run("virtual-atelier-renamed-source-is-preserved") { dir in
            let script = dir.appendingPathComponent("r6/scripts/custom-va/source/Listener.REDS")
            let original = Data("// User source checkout\r\npublic class VirtualAtelierSiteListener extends IScriptable {\r\n}\r\n".utf8)
            try write(script, original)
            check(ModImportPlan.hasVirtualAtelier(in: dir))
            check(try Data(contentsOf: script) == original)
            check(!fm.fileExists(atPath: dir.appendingPathComponent("r6/scripts/virtual-atelier-full").path))
        }
        try run("virtual-atelier-imports-and-store-scripts-are-not-core") { dir in
            let script = dir.appendingPathComponent("r6/scripts/PUBLICNET/Store.reds")
            let original = Data("""
                import VirtualAtelier.*
                // public class VirtualAtelierSiteListener extends IScriptable {}
                public class VirtualAtelierSiteListenerExtra extends IScriptable {}
                public class MyStoreListener extends VirtualAtelierSiteListener {}
                @addMethod(gameuiInGameMenuGameController)
                protected cb func RegisterStores(event: ref<VirtualShopRegistration>) -> Bool {
                  event.AddStore(n"PublicNet", "PUBLICNET", [], [], "base\\\\textures\\\\ui.inkatlas", n"icon");
                  return true;
                }
                """.utf8)
            try write(script, original)
            try write(dir.appendingPathComponent("archive/Mac/mod/PUBLICNET.archive"), Data("store archive".utf8))
            check(!ModImportPlan.hasVirtualAtelier(in: dir))
            check(try Data(contentsOf: script) == original)
        }
        func expectDuplicate(_ urls: [URL]) throws {
            do { try ModImportPlan.validate(urls); preconditionFailure("Expected duplicate manifest rejection") }
            catch is ModImportPlan.DuplicateName { }
        }
        try run("batch-same-zip-names-in-different-directories") { dir in
            let first = dir.appendingPathComponent("first/Shop.zip")
            let second = dir.appendingPathComponent("second/Shop.zip")
            try write(first, Data("first source".utf8))
            try write(second, Data("second source".utf8))
            try expectDuplicate([first, second])
            check(try Data(contentsOf: first) == Data("first source".utf8))
            check(try Data(contentsOf: second) == Data("second source".utf8))
        }
        try run("batch-case-insensitive-name-collision") { dir in
            let first = dir.appendingPathComponent("first/Shop.zip")
            let second = dir.appendingPathComponent("second/sHoP.ZIP")
            try write(first, Data([1])); try write(second, Data([2]))
            try expectDuplicate([first, second])
        }
        try run("batch-folder-and-zip-collision") { dir in
            let folder = dir.appendingPathComponent("Shop", isDirectory: true)
            let zip = dir.appendingPathComponent("Shop.zip")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(zip, Data([1]))
            try expectDuplicate([folder, zip])
        }
        try run("batch-dotted-folder-names-retained") { dir in
            let first = dir.appendingPathComponent("Shop.1.0", isDirectory: true)
            let second = dir.appendingPathComponent("Shop.1.1", isDirectory: true)
            try fm.createDirectory(at: first, withIntermediateDirectories: true)
            try fm.createDirectory(at: second, withIntermediateDirectories: true)
            check(ModImportPlan.manifestBase(for: first) == "Shop.1.0")
            check(ModImportPlan.manifestBase(for: second) == "Shop.1.1")
            try ModImportPlan.validate([first, second])
        }
        try run("batch-distinct-mixed-inputs") { dir in
            let folder = dir.appendingPathComponent("Shop A", isDirectory: true)
            let zip = dir.appendingPathComponent("Shop B.1.2.zip")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(zip, Data([1]))
            check(ModImportPlan.manifestBase(for: zip) == "Shop B.1.2")
            try ModImportPlan.validate([folder, zip])
        }
        // An optional prepared Resources fixture checks the Python/Swift schema contract.
        if CommandLine.arguments.count == 2 {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let catalog = try OptionalModCatalog.load(resources: resources)
            check(Dictionary(uniqueKeysWithValues: catalog.mods.map { ($0.id, $0.files.count) }) == ["equipment-ex": 6, "cyberware-ex": 41])
            for mod in catalog.mods { _ = try catalog.verifiedPackage(for: mod) }
            passed += 1
            print("PASS prepared-runtime-payload-contract")
        }
        print("\(passed) optional mod catalogue filesystem checks passed")
    }
}
