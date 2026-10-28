import Foundation
import CryptoKit

/// Installs only NightCity's two version-specific scripts. Unknown files and
/// edited copies are never overwritten or removed, including during uninstall.
enum ExplorationScripts {
    static let filenames: Set<String> = ["NCCCollisionFlightProbe.reds", "NCCFlightClearance.reds"]
    static let stagePath = "r6/scripts/NightCityExploration"
    static let manifestPath = "red4ext/nightcity-exploration.json"

    struct Manifest: Codable, Equatable {
        let schema: Int
        let gameVersion: String
        let files: [String: String]
        enum CodingKeys: String, CodingKey { case schema, gameVersion = "game_version", files }
    }
    struct Conflict: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Plan {
        let writes: [URL: Data]
        let removals: [URL]
        let manifestURL: URL
        let manifest: Manifest?
        let manifestChanged: Bool
        var current: Bool { writes.isEmpty && removals.isEmpty && !manifestChanged }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Check every existing path component before following it. The accepted
    // namespace is fixed by this source, never supplied by an install manifest.
    private static func checkedURL(_ root: URL, _ relative: String) throws -> URL {
        let fm = FileManager.default
        var target = root.standardizedFileURL
        for component in [""] + relative.split(separator: "/").map(String.init) {
            if !component.isEmpty { target.appendPathComponent(component) }
            do {
                let attributes = try fm.attributesOfItem(atPath: target.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw Conflict(message: "Kept a linked Exploration path: \(relative). Use a regular game folder before trying again.")
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                continue
            }
        }
        return target
    }

    private static func readFile(_ url: URL) throws -> Data? {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 4 * 1024 * 1024 else {
            throw Conflict(message: "Kept an unexpected Exploration file: \(url.lastPathComponent). Back it up and move it outside the game folder before trying again.")
        }
        return try Data(contentsOf: url)
    }

    private static func decode(_ data: Data, complete: Bool) throws -> Manifest {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schema == 1, manifest.gameVersion == "2.5.0",
              Set(manifest.files.keys).isSubset(of: filenames),
              !complete || Set(manifest.files.keys) == filenames,
              manifest.files.values.allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else {
            throw Conflict(message: complete
                ? "Bundled Exploration script manifest is invalid. Reinstall NightCity Console from its original download; existing scripts were kept."
                : "Kept invalid Exploration ownership manifest: \(manifestPath). Back it up and move it outside the game folder before trying again.")
        }
        return manifest
    }

    private static func payload(_ resources: URL, required: Bool) throws -> [String: Data] {
        let root = try checkedURL(resources, "exploration")
        guard let data = try readFile(try checkedURL(root, "manifest.json")) else {
            if !required { return [:] }
            throw Conflict(message: "Bundled Exploration scripts are missing. Reinstall NightCity Console from its original download.")
        }
        let manifest = try decode(data, complete: true)
        var result: [String: Data] = [:]
        for name in filenames.sorted() {
            guard let bytes = try readFile(try checkedURL(root, name)), !bytes.isEmpty, hash(bytes) == manifest.files[name] else {
                throw Conflict(message: "Bundled Exploration script is missing or damaged: \(name). Reinstall NightCity Console from its original download.")
            }
            result[name] = bytes
        }
        return result
    }

    private static func plan(gameRoot: URL, resources: URL, enabled: Bool) throws -> Plan {
        let manifestURL = try checkedURL(gameRoot, manifestPath)
        let previousData = try readFile(manifestURL)
        // Older games and uninstall must leave an unowned scripts namespace
        // alone, including custom layouts using a linked r6/scripts directory.
        if !enabled && previousData == nil {
            return Plan(writes: [:], removals: [], manifestURL: manifestURL,
                        manifest: nil, manifestChanged: false)
        }
        let previous = try previousData.map { try decode($0, complete: false) }
        let known = enabled ? try payload(resources, required: true) : [:]
        let desired = enabled ? known : [:]
        var writes: [URL: Data] = [:], removals: [URL] = []
        let managedNames = enabled ? filenames : Set(previous?.files.keys.map { $0 } ?? [])
        for name in managedNames.sorted() {
            let target = try checkedURL(gameRoot, stagePath + "/" + name)
            let existing = try readFile(target)
            if existing == desired[name] { continue }
            if let existing {
                guard previous?.files[name] == hash(existing) || known[name] == existing else {
                    throw Conflict(message: "Kept older or edited Exploration script: \(stagePath)/\(name). Back up and move this file outside r6/scripts before trying again.")
                }
            }
            if let bytes = desired[name] { writes[target] = bytes }
            else if existing != nil { removals.append(target) }
        }
        let next = enabled ? Manifest(schema: 1, gameVersion: "2.5.0", files: desired.mapValues(hash)) : nil
        return Plan(writes: writes, removals: removals, manifestURL: manifestURL,
                    manifest: next, manifestChanged: previous != next)
    }

    static func isCurrent(gameRoot: URL, resources: URL, enabled: Bool) -> Bool {
        (try? plan(gameRoot: gameRoot, resources: resources, enabled: enabled).current) == true
    }

    static func reconcile(gameRoot: URL, resources: URL, enabled: Bool) throws {
        // Preflight every owned path and the manifest before changing anything.
        let operation = try plan(gameRoot: gameRoot, resources: resources, enabled: enabled)
        guard !operation.current else { return }
        let fm = FileManager.default
        for (url, bytes) in operation.writes.sorted(by: { $0.key.path < $1.key.path }) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
        for url in operation.removals { try fm.removeItem(at: url) }
        if operation.manifestChanged {
            if let manifest = operation.manifest {
                try fm.createDirectory(at: operation.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: operation.manifestURL, options: .atomic)
            } else {
                try fm.removeItem(at: operation.manifestURL)
            }
        }
        if !enabled {
            let stage = try checkedURL(gameRoot, stagePath)
            if (try? fm.contentsOfDirectory(atPath: stage.path))?.isEmpty == true { try fm.removeItem(at: stage) }
        }
    }
}
