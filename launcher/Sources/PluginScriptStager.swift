import Foundation
import CryptoKit

/// Owns only the byte-identified copies compiled from verified native plugins.
/// The manifest lives outside r6/scripts, and unrelated mod sources are never touched.
enum PluginScriptStager {
    struct Conflict: LocalizedError {
        let paths: [String]
        var errorDescription: String? {
            "Plugin script copies were kept because they contain older or edited content: "
                + paths.prefix(4).joined(separator: ", ")
                + ". Move those copies outside r6/scripts before trying again."
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func scripts(in root: URL) throws -> [String: Data] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [:] }
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw Conflict(paths: [root.path]) }
        guard let files = fm.enumerator(atPath: root.path) else { return [:] }
        var result: [String: Data] = [:]
        for case let relative as String in files {
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let url = root.appendingPathComponent(relative)
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw Conflict(paths: [url.path]) }
            if properties.isRegularFile == true && url.pathExtension == "reds" {
                result[relative] = try Data(contentsOf: url)
            }
        }
        return result
    }

    /// Reconcile accepted plugin scripts and remove identical legacy copies such as r6/scripts/TweakXL.
    /// `knownSources` also identifies obsolete staged copies from plugins the loader now refuses.
    /// With an empty accepted set this removes only owned staged files, for leaving game 2.5.
    static func reconcile(accepted: [String: URL], knownSources: [String: URL], scriptsRoot: URL,
                          manifestURL: URL) throws {
        let fm = FileManager.default
        let stage = scriptsRoot.appendingPathComponent("zz_nightcity_plugins")
        let previous: [String: String]
        if fm.fileExists(atPath: manifestURL.path) {
            previous = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
        } else {
            previous = [:]
        }
        func collect(_ roots: [String: URL]) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for (name, root) in roots {
                guard name != ".", name != "..", !name.contains("/"), !name.isEmpty else {
                    throw Conflict(paths: [name])
                }
                for (relative, data) in try scripts(in: root) { result["\(name)/\(relative)"] = data }
            }
            return result
        }
        let desired = try collect(accepted)
        let known = try collect(knownSources.merging(accepted) { _, new in new })
        let existing = try scripts(in: stage)
        if desired.isEmpty && existing.isEmpty && previous.isEmpty { return }
        var conflicts: [String] = []
        for (relative, data) in existing where desired[relative] != data {
            guard previous[relative] == hash(data) || known[relative] == data else {
                conflicts.append("zz_nightcity_plugins/\(relative)")
                continue
            }
        }
        var legacyDuplicates: [URL] = []
        for name in accepted.keys.sorted() {
            let legacy = scriptsRoot.appendingPathComponent(name)
            for (relative, data) in try scripts(in: legacy) {
                if desired["\(name)/\(relative)"] == data {
                    legacyDuplicates.append(legacy.appendingPathComponent(relative))
                } else {
                    conflicts.append("\(name)/\(relative)")
                }
            }
        }
        // Check the entire operation before changing anything, including the ownership manifest.
        guard conflicts.isEmpty else { throw Conflict(paths: conflicts.sorted()) }
        for (relative, data) in desired.sorted(by: { $0.key < $1.key }) where existing[relative] != data {
            let target = stage.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        for relative in existing.keys where desired[relative] == nil {
            try fm.removeItem(at: stage.appendingPathComponent(relative))
        }
        for url in legacyDuplicates { try fm.removeItem(at: url) }
        let ownership = desired.mapValues(hash)
        try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ownership).write(to: manifestURL, options: .atomic)
    }
}
