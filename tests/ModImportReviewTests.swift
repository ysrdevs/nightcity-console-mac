import Foundation
import CryptoKit

@main
struct ModImportReviewTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nightcity-import-review-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func write(_ url: URL, _ data: Data) throws { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url) }
        func script(_ url: URL, _ text: String) throws { try write(url, Data(text.utf8)) }
        func game(_ directory: URL, foundations: Bool = true) throws -> URL {
            let game = directory.appendingPathComponent("game")
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.5.0"], format: .xml, options: 0)
            try write(game.appendingPathComponent("Cyberpunk2077.app/Contents/Info.plist"), info)
            if foundations {
                for path in ["engine/tools/scc", "engine/tools/libscc_lib.dylib", "red4ext/RED4ext.dylib", "red4ext/plugins/Codeware/Codeware.dylib", "red4ext/plugins/ArchiveXL/ArchiveXL.dylib", "red4ext/plugins/TweakXL/TweakXL.dylib", "red4ext/plugins/input_loader/input_loader.dylib", "red4ext/plugins/ModSettings/ModSettings.dylib"] {
                    try write(game.appendingPathComponent(path), Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1] + Array(repeating: UInt8(0), count: 24)))
                }
            }
            return game
        }
        func package(_ directory: URL, _ game: URL, _ name: String, _ payload: [String: String], receipt: String? = nil) throws -> ModPreparedImport {
            let workspace = directory.appendingPathComponent("work-" + UUID().uuidString)
            var files = [ModImportPreparationReport.File](), sources = [ModImportPreparationReport.SourceFile]()
            for (destination, text) in payload.sorted(by: { $0.key < $1.key }) {
                let data = Data(text.utf8), source = "game/" + destination
                // Invalid paths are introduced by report mutation, not fixture writes.
                try write(workspace.appendingPathComponent(source), data)
                try write(workspace.appendingPathComponent("source/" + destination), data)
                files.append(.init(source: source, destination: destination, sha256: hash(data), size: Int64(data.count)))
                sources.append(.init(path: destination, sha256: hash(data), size: Int64(data.count)))
            }
            let info = try Data(contentsOf: game.appendingPathComponent("Cyberpunk2077.app/Contents/Info.plist"))
            let report = ModImportPreparationReport(schema: 1, packageName: name, sourceName: name + ".zip", sourceFingerprint: String(repeating: "a", count: 64), gameVersion: "2.5.0", gameRoot: game.path, gameInfoSHA256: hash(info), files: files, sourceFiles: sources, skipped: [], issues: [])
            return ModPreparedImport(report: report, workspace: workspace, receiptName: receipt)
        }
        func changed(_ input: ModPreparedImport, _ mutation: (inout [String: Any]) -> Void) throws -> ModPreparedImport {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input.report)) as! [String: Any]
            mutation(&json)
            let report = try JSONDecoder().decode(ModImportPreparationReport.self, from: JSONSerialization.data(withJSONObject: json))
            return ModPreparedImport(report: report, workspace: input.workspace, receiptName: input.receiptName)
        }
        func has(_ review: ModImportBatchReview, _ code: String) -> Bool { (review.issues + review.packages.flatMap(\.issues)).contains { $0.code == code } }
        func dependency(_ review: ModImportBatchReview, _ id: String, package index: Int = 0) -> ModImportDependency? { review.packages[index].dependencies.first { $0.id == id } }
        func run(_ name: String, _ body: (URL) throws -> Void) throws {
            let dir = root.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try body(dir); count += 1; print("PASS \(name)")
        }
        try run("unknown-archive-has-warning-not-compatibility-claim") { dir in
            let g = try game(dir, foundations: false)
            let p = try package(dir, g, "Texture", ["archive/Mac/mod/texture.archive": "archive fixture"])
            let review = ModImportReview.analyze([p], gameRoot: g)
            check(review.canInstall && review.fileCount == 1 && has(review, "requirements-unknown"), "Unknown archive review")
            check(review.packages[0].version == nil && review.packages[0].identifiedMod == nil, "No guessed identity/version")
        }
        try run("all-filetype-and-script-dependencies") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/main.reds": "import Codeware.UI.*\n@runtimeProperty(\"ModSettings.mod\", \"Feature\")\npublic let enabled: Bool;\npublic class Patch extends ScriptableTweak {}", "r6/tweaks/feature.yaml": "x: 1", "r6/input/feature.xml": "<bindings/>", "red4ext/plugins/ArchiveXL/Bundle/feature.archive.xl": "localization: {}"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(r.canInstall, "Installed dependencies must pass")
            for key in ["redscript", "red4ext", "codeware", "tweakxl", "archivexl", "inputloader", "modsettings"] { check(dependency(r, key)?.status == .installed, "Missing inferred \(key)") }
            check(dependency(r, "modsettings")?.evidence.first?.contains("main.reds:") == true, "Source line evidence")
        }
        try run("missing-native-framework-blocks") { dir in
            let g = try game(dir)
            try fm.removeItem(at: g.appendingPathComponent("red4ext/plugins/Codeware/Codeware.dylib"))
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/main.reds": "import Codeware.UI.*"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && dependency(r, "codeware")?.status == .missing, "Missing Codeware")
        }
        try run("windows-binary-is-not-installed-native-foundation") { dir in
            let g = try game(dir)
            try script(g.appendingPathComponent("red4ext/plugins/ModSettings/ModSettings.dylib"), "MZ Windows file")
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/main.reds": "public func Test() { ModSettings.GetInstance(); }"])
            check(!ModImportReview.analyze([p], gameRoot: g).canInstall, "Do not accept PE or empty marker")
        }
        try run("optional-va-equipment-import-does-not-require-equipment") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Atelier", ["r6/scripts/RenamedVA/main.reds": "module VirtualAtelier.Site\npublic class VirtualAtelierSiteListener {}\n@if(ModuleExists(\"EquipmentEx\"))\nimport EquipmentEx.OutfitSystem\n@if(ModuleExists(\"EquipmentEx\"))\n@addMethod(PlayerPuppet)\npublic func OptionalOutfit() { EquipmentEx.SomeCall(); }\n"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(r.canInstall && dependency(r, "equipmentex")?.status == .optional, "VA optional integration became hard dependency")
            check(r.packages[0].identifiedMod == "Virtual Atelier", "VA defining signature")
        }
        try run("optional-does-not-hide-unconditional-use") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/main.reds": "@if(ModuleExists(\"EquipmentEx\"))\nimport EquipmentEx.OutfitSystem\npublic func Required() { EquipmentEx.RequiredCall(); }"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && dependency(r, "equipmentex")?.status == .missing, "Required use after optional declaration")
        }
        try run("optional-annotation-does-not-require-loader") { dir in
            let g = try game(dir)
            try fm.removeItem(at: g.appendingPathComponent("red4ext/RED4ext.dylib"))
            try fm.removeItem(at: g.appendingPathComponent("red4ext/plugins/ModSettings/ModSettings.dylib"))
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/main.reds": "@if(ModuleExists(\"UnknownOptional\"))\n@runtimeProperty(\"ModSettings.mod\", \"Optional\")\npublic let setting: Bool;"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(r.canInstall && dependency(r, "modsettings")?.status == .optional && dependency(r, "red4ext")?.status == .optional, "Conditional metadata dependency")
        }
        try run("batch-provides-va-and-own-modules") { dir in
            let g = try game(dir)
            let store = try package(dir, g, "Store", ["r6/scripts/Store/main.reds": "public func Store(event: ref<VirtualShopRegistration>) { event.AddStore(); }"])
            let va = try package(dir, g, "Atelier", ["r6/scripts/VA/main.reds": "module VirtualAtelier.Site\npublic class VirtualAtelierSiteListener {}\nimport VirtualAtelier.Site.*\n"])
            let r = ModImportReview.analyze([store, va], gameRoot: g)
            check(r.canInstall && dependency(r, "va")?.status == .selected, "Entire incoming batch considered")
            check(dependency(r, "va", package: 1) == nil, "VA must not require itself")
        }
        try run("store-without-va-blocks") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Store", ["r6/scripts/Store/main.reds": "public func Store(event: ref<VirtualShopRegistration>) {}"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && dependency(r, "va")?.status == .missing, "Store dependency")
        }
        try run("comments-strings-and-filenames-are-not-dependencies") { dir in
            let g = try game(dir, foundations: true)
            try fm.removeItem(at: g.appendingPathComponent("red4ext/plugins/Codeware/Codeware.dylib"))
            let p = try package(dir, g, "EquipmentEx-1.2.9", ["r6/scripts/CodewareExample/main.reds": "// import Codeware.UI.*\n/* EquipmentEx.Require(); */\npublic func Text() -> String { let Codeware: Bool = false; return \"ModSettings.GetInstance()\"; }"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(r.canInstall && r.packages[0].dependencies.map(\.id) == ["redscript"], "Comments and examples are not requirements")
            check(r.packages[0].identifiedMod == nil && r.packages[0].version == nil, "Do not trust filename version")
        }
        for (key, name) in [("va", "VirtualAtelierSiteListener"), ("equipmentex", "EquipmentEx"), ("cyberwareex", "CyberwareEx")] {
            try run("renamed-existing-core-\(key)") { dir in
                let g = try game(dir)
                try script(g.appendingPathComponent("r6/scripts/PlayerRenamedFolder/unique.reds"), "public abstract class \(name) {}")
                let p = try package(dir, g, "NewCore", ["r6/scripts/DifferentFolder/unique.reds": "public abstract class \(name) {}"])
                let r = ModImportReview.analyze([p], gameRoot: g)
                check(!r.canInstall && has(r, "existing-core"), "Renamed duplicate \(key)")
            }
        }
        try run("duplicate-core-within-batch") { dir in
            let g = try game(dir)
            let a = try package(dir, g, "First", ["r6/scripts/A/a.reds": "public abstract class EquipmentEx {}"])
            let b = try package(dir, g, "Second", ["r6/scripts/B/b.reds": "public abstract class EquipmentEx {}"])
            let r = ModImportReview.analyze([a, b], gameRoot: g)
            check(!r.canInstall && has(r, "duplicate-core"), "Batch duplicate core")
        }
        try run("selected-optional-integration-becomes-present") { dir in
            let g = try game(dir)
            let a = try package(dir, g, "Feature", ["r6/scripts/Feature/a.reds": "@if(ModuleExists(\"EquipmentEx\"))\nimport EquipmentEx.OutfitSystem"])
            let b = try package(dir, g, "Equipment", ["r6/scripts/Equipment/b.reds": "module EquipmentEx\npublic abstract class EquipmentEx {}"])
            let r = ModImportReview.analyze([a, b], gameRoot: g)
            check(r.canInstall && dependency(r, "equipmentex")?.status == .selected, "Evaluate selected module condition")
        }
        try run("existing-and-casefold-batch-files-block") { dir in
            let g = try game(dir)
            try script(g.appendingPathComponent("r6/tweaks/Existing.yaml"), "old")
            let a = try package(dir, g, "First", ["r6/tweaks/existing.yaml": "new", "r6/tweaks/shared.yaml": "one"])
            let b = try package(dir, g, "Second", ["r6/tweaks/SHARED.yaml": "two"])
            let r = ModImportReview.analyze([a, b], gameRoot: g)
            check(!r.canInstall && has(r, "existing-file") && has(r, "batch-file-conflict"), "No overwrite even case aliases")
            check(try String(contentsOf: g.appendingPathComponent("r6/tweaks/Existing.yaml"), encoding: .utf8) == "old", "Review is read-only")
        }
        try run("nonadjacent-parent-conflict") { dir in
            let g = try game(dir)
            let a = try package(dir, g, "First", ["r6/tweaks/a": "a", "r6/tweaks/a-b": "b"])
            let b = try package(dir, g, "Second", ["r6/tweaks/a/child.yaml": "child"])
            let r = ModImportReview.analyze([a, b], gameRoot: g)
            check(!r.canInstall && has(r, "batch-file-conflict"), "Ancestor conflict must survive intervening sorted entry")
        }
        try run("existing-empty-receipt-and-batch-receipt") { dir in
            let g = try game(dir)
            try script(g.appendingPathComponent("red4ext/nightcity/mods/Custom.json"), "{\"files\":[]}")
            let a = try package(dir, g, "First", ["r6/tweaks/a.yaml": "a"], receipt: "custom.json")
            let b = try package(dir, g, "Second", ["r6/tweaks/b.yaml": "b"], receipt: "CUSTOM.json")
            let r = ModImportReview.analyze([a, b], gameRoot: g)
            check(!r.canInstall && has(r, "existing-receipt") && has(r, "receipt-conflict"), "Empty receipts still own names")
        }
        try run("runtime-protection-and-backend-findings") { dir in
            let g = try game(dir)
            let original = try package(dir, g, "Unsafe", ["red4ext/plugins/Codeware/settings.json": "{}", "r6/scripts/zz_nightcity_plugins/New/a.reds": "public class New {}"])
            let p = try changed(original) { $0["skipped"] = [["path": "red4ext/plugins/Unknown.dll", "reason": "Windows plugin", "blocking": true]] }
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && has(r, "protected-runtime") && has(r, "skipped-file"), "Protected runtime and native blocker retained")
        }
        try run("prepared-script-tampering-blocks") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/a.reds": "public class A {}"])
            try script(p.workspace.appendingPathComponent(p.report.files[0].source), "public class B {}")
            check(has(ModImportReview.analyze([p], gameRoot: g), "script-inspection"), "Changed snapshot refused")
        }
        try run("unsafe-path-report-and-game-change-block") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/a.reds": "public class A {}"])
            let invalid = try changed(p) { json in var files = json["files"] as! [[String: Any]]; files[0]["destination"] = "../outside.reds"; json["files"] = files }
            check(has(ModImportReview.analyze([invalid], gameRoot: g), "invalid-file"), "Traversal refused")
            try script(g.appendingPathComponent("Cyberpunk2077.app/Contents/Info.plist"), "changed")
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && has(r, "game-changed") && has(r, "game-inspection"), "Game identity changed")
        }
        try run("installed-script-symlink-blocks-incomplete-inventory") { dir in
            let g = try game(dir)
            try script(dir.appendingPathComponent("outside.reds"), "public abstract class EquipmentEx {}")
            try fm.createDirectory(at: g.appendingPathComponent("r6/scripts"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: g.appendingPathComponent("r6/scripts/linked.reds"), withDestinationURL: dir.appendingPathComponent("outside.reds"))
            let p = try package(dir, g, "Feature", ["r6/tweaks/a.yaml": "x: 1"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && has(r, "installed-inspection"), "Inspection failure must not count as a complete inventory")
        }
        try run("boolean-guards-and-negation") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/main.reds": "@if(ModuleExists(\"Absent\") && !ModuleExists(\"Other\"))\nimport EquipmentEx.OutfitSystem\n@if(!ModuleExists(\"Absent\"))\npublic func Need() { CyberwareEx.Required(); }"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(dependency(r, "equipmentex")?.status == .optional && dependency(r, "cyberwareex")?.status == .missing, "Evaluate conditions without making negated present check mandatory")
        }
        try run("flat-script-and-preserved-foundation-notice") { dir in
            let g = try game(dir)
            let original = try package(dir, g, "Flat", ["r6/scripts/feature.reds": "import Codeware.UI.*"])
            let p = try changed(original) { $0["skipped"] = [["path": "red4ext/plugins/Codeware/Codeware.dll", "reason": "Kept bundled native Codeware", "blocking": false]] }
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(r.canInstall && has(r, "skipped-file"), "Flat script allowed, informational skip retained")
        }
        try run("oversized-installed-script-is-incomplete") { dir in
            let g = try game(dir)
            try write(g.appendingPathComponent("r6/scripts/oversize.reds"), Data(repeating: 32, count: 2 * 1024 * 1024 + 1))
            let p = try package(dir, g, "Archive", ["archive/Mac/mod/a.archive": "archive"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && has(r, "installed-inspection"), "Large file must not silently count as inspected")
        }
        try run("prepared-script-symlink-refused") { dir in
            let g = try game(dir)
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/a.reds": "public class A {}"])
            let file = p.workspace.appendingPathComponent(p.report.files[0].source)
            let saved = dir.appendingPathComponent("original.reds")
            try fm.moveItem(at: file, to: saved)
            try fm.createSymbolicLink(at: file, withDestinationURL: saved)
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && has(r, "script-inspection"), "Snapshot symlink is not followed")
        }
        try run("selected-provider-blocker-blocks-whole-batch") { dir in
            let g = try game(dir)
            let store = try package(dir, g, "Store", ["r6/scripts/Store/main.reds": "public func Store(event: ref<VirtualShopRegistration>) {}"])
            let original = try package(dir, g, "Atelier", ["r6/scripts/VA/main.reds": "public class VirtualAtelierSiteListener {}"])
            let va = try changed(original) { $0["issues"] = [["code": "unsupported", "message": "unsupported native component", "blocking": true]] }
            let r = ModImportReview.analyze([store, va], gameRoot: g)
            check(!r.canInstall && dependency(r, "va")?.status == .selected && has(r, "unsupported"), "Selected dependency doesn't override provider blockers")
        }
        try run("semicolon-free-guard-does-not-absorb-next-function") { dir in
            let g = try game(dir)
            try fm.removeItem(at: g.appendingPathComponent("red4ext/plugins/Codeware/Codeware.dylib"))
            let p = try package(dir, g, "Feature", ["r6/scripts/Feature/main.reds": "@if(ModuleExists(\"Absent\"))\npublic func Flag() -> Bool = true\npublic func Required() -> String { return Codeware.Version(); }"])
            let r = ModImportReview.analyze([p], gameRoot: g)
            check(!r.canInstall && dependency(r, "codeware")?.status == .missing, "Guard leaked across semicolon-free expression declaration")
        }
        try run("foundation-companion-assets-protected-thirdparty-allowed") { dir in
            let g = try game(dir)
            for name in ["ArchiveXL.archive", "Codeware.archive", "ModSettings.archive", "ModSettings.archive.xl"] {
                let p = try package(dir, g, "Foundation", ["archive/Mac/mod/" + name: "forged prepared asset"])
                let r = ModImportReview.analyze([p], gameRoot: g)
                check(!r.canInstall && has(r, "protected-runtime"), "Foundation companion was not protected: \(name)")
            }
            let forgedSidecar = try package(dir, g, "Sidecar", ["red4ext/plugins/ArchiveXL/Bundle/ModSettings.archive.xl": "metadata"])
            check(has(ModImportReview.analyze([forgedSidecar], gameRoot: g), "protected-runtime"), "Foundation Bundle sidecar")
            let ordinary = try package(dir, g, "Third party", ["archive/Mac/mod/Codeware-addon.archive": "archive", "red4ext/plugins/ArchiveXL/Bundle/thirdparty.archive.xl": "metadata"])
            check(ModImportReview.analyze([ordinary], gameRoot: g).canInstall, "Only exact foundation companions should be protected")
        }
        print("\(count) mod import review tests passed")
    }
}
