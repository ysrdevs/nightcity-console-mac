import Foundation

@main
struct ExplorationScriptsTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("nightcity-exploration-install-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let resources = fixture.appendingPathComponent("Resources")
        let names = ExplorationScripts.filenames.sorted()
        func write(_ url: URL, _ value: Data) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: url)
        }
        func file(_ game: URL, _ name: String) -> URL { game.appendingPathComponent(ExplorationScripts.stagePath + "/" + name) }
        func manifest(_ game: URL) -> URL { game.appendingPathComponent(ExplorationScripts.manifestPath) }
        func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }
        func bundle(_ version: String) throws -> [String: Data] {
            let bytes = Dictionary(uniqueKeysWithValues: names.map { ($0, Data((version + " " + $0).utf8)) })
            for (name, data) in bytes { try write(resources.appendingPathComponent("exploration/" + name), data) }
            let meta = ExplorationScripts.Manifest(schema: 1, gameVersion: "2.5.0", files: bytes.mapValues(ExplorationScripts.hash))
            try write(resources.appendingPathComponent("exploration/manifest.json"), JSONEncoder().encode(meta))
            return bytes
        }
        func game(_ name: String) throws -> URL {
            let value = fixture.appendingPathComponent(name)
            try fm.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        func current(_ game: URL, _ enabled: Bool = true) -> Bool {
            ExplorationScripts.isCurrent(gameRoot: game, resources: resources, enabled: enabled)
        }
        func install(_ game: URL, _ enabled: Bool = true) throws {
            try ExplorationScripts.reconcile(gameRoot: game, resources: resources, enabled: enabled)
        }
        func conflict(_ body: () throws -> Void) throws {
            do { try body(); preconditionFailure("Expected a preserved-file conflict") }
            catch is ExplorationScripts.Conflict { }
        }

        let first = try bundle("release-one"), selected = try game("Game25")
        let unrelated = file(selected, "AnotherMod.reds")
        try write(unrelated, Data("USER_SCRIPT".utf8))
        precondition(!current(selected))
        try install(selected)
        precondition(current(selected))
        for name in names { precondition(contents(file(selected, name)) == first[name]) }
        precondition(contents(unrelated) == Data("USER_SCRIPT".utf8))
        let installed = try JSONDecoder().decode(ExplorationScripts.Manifest.self, from: Data(contentsOf: manifest(selected)))
        precondition(installed.files == first.mapValues(ExplorationScripts.hash))
        print("PASS fresh install owns exactly two scripts and preserves additional scripts")

        let second = try bundle("release-two")
        precondition(!current(selected)); try install(selected); precondition(current(selected))
        for name in names { precondition(contents(file(selected, name)) == second[name]) }
        try fm.removeItem(at: file(selected, names[0]))
        precondition(!current(selected)); try install(selected); precondition(current(selected))
        print("PASS owned older versions update and missing copies self-heal")

        let beforeManifest = contents(manifest(selected)), beforeOther = contents(file(selected, names[1]))
        try write(file(selected, names[0]), Data("EDITED_PRIVATE_SCRIPT".utf8))
        precondition(!current(selected))
        try conflict { try install(selected) }
        try conflict { try install(selected, false) }
        precondition(contents(file(selected, names[0])) == Data("EDITED_PRIVATE_SCRIPT".utf8))
        precondition(contents(file(selected, names[1])) == beforeOther && contents(manifest(selected)) == beforeManifest)
        try write(file(selected, names[0]), second[names[0]]!)
        try install(selected, false)
        precondition(current(selected, false) && contents(manifest(selected)) == nil)
        precondition(names.allSatisfy { contents(file(selected, $0)) == nil })
        precondition(contents(unrelated) == Data("USER_SCRIPT".utf8))
        print("PASS edit conflict preflights the whole operation and uninstall preserves unrelated files")

        let legacy = try game("Game231")
        precondition(current(legacy, false)); try install(legacy, false)
        precondition(!fm.fileExists(atPath: legacy.appendingPathComponent("r6").path))
        precondition(!fm.fileExists(atPath: legacy.appendingPathComponent("red4ext").path))
        try install(legacy); try install(legacy, false)
        precondition(names.allSatisfy { contents(file(legacy, $0)) == nil } && current(legacy, false))
        print("PASS non-2.5 never receives scripts and removes only owned copies on version change")

        let manual = try game("Manual"), foreign = try game("Foreign")
        for name in names { try write(file(manual, name), second[name]!) }
        try install(manual, false)
        precondition(contents(manifest(manual)) == nil && names.allSatisfy { contents(file(manual, $0)) == second[$0] })
        precondition(!current(manual)); try install(manual); precondition(current(manual))
        try write(file(foreign, names[0]), Data("FOREIGN_SCRIPT".utf8))
        try conflict { try install(foreign) }
        try install(foreign, false)
        precondition(contents(file(foreign, names[1])) == nil && contents(manifest(foreign)) == nil)
        precondition(contents(file(foreign, names[0])) == Data("FOREIGN_SCRIPT".utf8))
        print("PASS exact current manual copies can be adopted; unknown copies cannot")

        let badManifest = try game("BadManifest")
        try write(manifest(badManifest), Data("{malformed".utf8))
        try conflict { try install(badManifest) }
        let malicious = ExplorationScripts.Manifest(schema: 1, gameVersion: "2.5.0", files: ["../outside.reds": String(repeating: "a", count: 64)])
        try write(manifest(badManifest), JSONEncoder().encode(malicious))
        try conflict { try install(badManifest, false) }
        precondition(names.allSatisfy { contents(file(badManifest, $0)) == nil })
        print("PASS malformed and out-of-namespace manifests cannot authorize changes")

        let linked = try game("Linked"), outside = fixture.appendingPathComponent("outside.reds")
        try write(outside, second[names[0]]!)
        try fm.createDirectory(at: file(linked, names[0]).deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: file(linked, names[0]), withDestinationURL: outside)
        try conflict { try install(linked) }
        try install(linked, false)
        precondition(contents(outside) == second[names[0]] && contents(file(linked, names[1])) == nil)
        let linkedDirectory = try game("LinkedDirectory")
        try fm.createDirectory(at: linkedDirectory.appendingPathComponent("r6"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedDirectory.appendingPathComponent("r6/scripts"), withDestinationURL: fixture)
        try conflict { try install(linkedDirectory) }
        precondition(current(linkedDirectory, false))
        try install(linkedDirectory, false)
        precondition(contents(manifest(linkedDirectory)) == nil && !fm.fileExists(atPath: fixture.appendingPathComponent("NightCityExploration").path))
        precondition((try? fm.destinationOfSymbolicLink(atPath: linkedDirectory.appendingPathComponent("r6/scripts").path)) == fixture.path)
        let linkedManifest = try game("LinkedManifest")
        try fm.createDirectory(at: linkedManifest.appendingPathComponent("red4ext"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: manifest(linkedManifest), withDestinationURL: manifest(manual))
        try conflict { try install(linkedManifest) }
        print("PASS file, directory and manifest symlinks cannot redirect installation or cleanup")
        print("PASS disabled unowned installs preserve current manual copies and unrelated linked script layouts")

        try write(resources.appendingPathComponent("exploration/" + names[0]), Data("TAMPERED_BUNDLE".utf8))
        let missing = try game("MissingBundle")
        try conflict { try install(missing) }
        precondition(!fm.fileExists(atPath: missing.appendingPathComponent("r6").path))
        try install(missing, false)
        precondition(current(missing, false) && !fm.fileExists(atPath: missing.appendingPathComponent("r6").path))
        print("PASS damaged bundled script hashes prevent partial installation")
    }
}
