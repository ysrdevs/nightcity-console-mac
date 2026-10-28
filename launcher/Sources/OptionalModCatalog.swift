import Foundation
import CryptoKit

struct OptionalMod: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let package: String
    let files: [String: String]
    let scriptDirectory: String

    enum CodingKeys: String, CodingKey {
        case id, name, version, package, files
        case scriptDirectory = "script_directory"
    }
}

enum OptionalModError: LocalizedError {
    case missingCatalog, invalidCatalog, invalidPackage(String), alreadyInstalled(String)
    var errorDescription: String? {
        switch self {
        case .missingCatalog: return "Optional mod packs are missing from this app. Download the complete NightCity Console app again."
        case .invalidCatalog: return "The bundled optional mod catalogue is invalid. Download the complete NightCity Console app again."
        case .invalidPackage(let name): return "The bundled \(name) package is missing or damaged. Download the complete NightCity Console app again."
        case .alreadyInstalled(let name): return "\(name) is already present. Keep your existing installation, or remove it before installing the bundled version."
        }
    }
}

struct OptionalModCatalog {
    let mods: [OptionalMod]
    let root: URL

    private static let maximumPackageBytes = 32 * 1024 * 1024
    private static let maximumFiles = 256
    private static let versions = ["equipment-ex": "1.2.9", "cyberware-ex": "1.5.6"]
    private static let directories = ["equipment-ex": "r6/scripts/EquipmentEx", "cyberware-ex": "r6/scripts/CyberwareEx"]

    private struct Manifest: Decodable {
        let schema: Int
        let gameVersion: String
        let mods: [OptionalMod]
        enum CodingKeys: String, CodingKey {
            case schema, mods
            case gameVersion = "game_version"
        }
    }

    // Resources is the trusted boundary. Check it and every package ancestor without
    // resolving links inside the payload; normal system aliases above Resources are allowed.
    private static func ordinaryAncestors(of url: URL, within resources: URL) -> Bool {
        guard url.isFileURL, resources.isFileURL, resources.path.hasPrefix("/"),
              url.path.hasPrefix(resources.path + "/") else { return false }
        var parent = url.deletingLastPathComponent()
        while true {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
            if parent.path == resources.path { return true }
            guard parent.path.hasPrefix(resources.path + "/") else { return false }
            parent.deleteLastPathComponent()
        }
    }

    private static func regularData(at url: URL, within resources: URL, limit: Int) -> Data? {
        guard ordinaryAncestors(of: url, within: resources),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count == size, data.count <= limit else { return nil }
        return data
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"),
              path.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-").contains($0) }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count <= 16 && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 128 }
    }

    static func load(resources: URL?) throws -> OptionalModCatalog {
        guard let resources else { throw OptionalModError.missingCatalog }
        let root = resources.appendingPathComponent("optional-mods", isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = regularData(at: manifestURL, within: resources, limit: 128 * 1024) else {
            if (try? FileManager.default.attributesOfItem(atPath: manifestURL.path)) == nil {
                throw OptionalModError.missingCatalog
            }
            throw OptionalModError.invalidCatalog
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schema == 2, manifest.gameVersion == "2.5.0",
              Set(manifest.mods.map(\.id)) == ["equipment-ex", "cyberware-ex"], manifest.mods.count == 2 else {
            throw OptionalModError.invalidCatalog
        }
        for mod in manifest.mods {
            guard mod.scriptDirectory == directories[mod.id], mod.version == versions[mod.id],
                  mod.package == "\(mod.id)-\(mod.version)",
                  !mod.name.isEmpty, mod.name.utf8.count <= 80,
                  !mod.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !mod.files.isEmpty, mod.files.count <= maximumFiles,
                  mod.files["\(mod.scriptDirectory)/LICENSE"] != nil,
                  mod.files.allSatisfy({ path, hash in safeRelativePath(path) && hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) } }) else {
                throw OptionalModError.invalidCatalog
            }
            // Case aliases and a file that is also another file's parent cannot be represented safely.
            let paths = Set(mod.files.keys.map { $0.lowercased() })
            guard paths.count == mod.files.count, paths.allSatisfy({ path in
                let components = path.split(separator: "/")
                return !(1..<components.count).contains { paths.contains(components.prefix($0).joined(separator: "/")) }
            }) else { throw OptionalModError.invalidCatalog }
        }
        return OptionalModCatalog(mods: manifest.mods, root: root)
    }

    func verifiedPackage(for mod: OptionalMod) throws -> URL {
        guard mods.contains(mod) else { throw OptionalModError.invalidCatalog }
        let package = root.appendingPathComponent(mod.package, isDirectory: true)
        let fm = FileManager.default
        guard Self.ordinaryAncestors(of: package, within: root.deletingLastPathComponent()),
              let attributes = try? fm.attributesOfItem(atPath: package.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw OptionalModError.invalidPackage(mod.name)
        }
        var expectedDirectories = Set<String>()
        for path in mod.files.keys {
            let parts = path.split(separator: "/")
            for count in 1..<parts.count { expectedDirectories.insert(parts.prefix(count).joined(separator: "/")) }
        }
        var pending = [""]
        var seen = Set<String>()
        var totalBytes = 0
        while let relativeDirectory = pending.popLast() {
            let directory = relativeDirectory.isEmpty ? package : package.appendingPathComponent(relativeDirectory, isDirectory: true)
            guard Self.ordinaryAncestors(of: directory, within: root.deletingLastPathComponent()),
                  (try? fm.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
                  let children = try? fm.contentsOfDirectory(atPath: directory.path),
                  children.count <= mod.files.count + expectedDirectories.count else { throw OptionalModError.invalidPackage(mod.name) }
            for child in children {
                let relative = relativeDirectory.isEmpty ? child : relativeDirectory + "/" + child
                guard Self.safeRelativePath(relative) else { throw OptionalModError.invalidPackage(mod.name) }
                let url = package.appendingPathComponent(relative)
                guard let type = (try? fm.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType else { throw OptionalModError.invalidPackage(mod.name) }
                if type == .typeDirectory {
                    guard expectedDirectories.contains(relative) else { throw OptionalModError.invalidPackage(mod.name) }
                    pending.append(relative)
                } else {
                    guard type == .typeRegular, let expectedHash = mod.files[relative],
                          let data = Self.regularData(at: url, within: root.deletingLastPathComponent(), limit: Self.maximumPackageBytes - totalBytes),
                          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedHash else { throw OptionalModError.invalidPackage(mod.name) }
                    totalBytes += data.count
                    seen.insert(relative)
                }
            }
        }
        guard seen == Set(mod.files.keys) else { throw OptionalModError.invalidPackage(mod.name) }
        return package
    }

    // The helper strips the final dotted suffix from its receipt's display name for folders.
    // The explicit receipt filename remains stable across ZIP and folder installs.
    static func installedDisplayName(manifestFilename: String) -> String? {
        for (id, version) in versions where manifestFilename == "\(id)-\(version).json" {
            return "\(id)-\(version)"
        }
        return nil
    }

    // Do not take ownership of a player's manual install or lay a second source layout over it.
    // Empty directories left after a managed uninstall do not count as an installed mod.
    static func installedStatus(_ mod: OptionalMod, gameRoot: URL) -> String? {
        let fm = FileManager.default
        let scripts = gameRoot.appendingPathComponent(mod.scriptDirectory)
        let hasCanonicalScripts = fm.enumerator(at: scripts, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?.contains(where: { value in
            guard let url = value as? URL, url.pathExtension.lowercased() == "reds" else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }) ?? false
        // Source installations can live in a renamed folder. Detect their own module/facade,
        // but not another mod's imports of EquipmentEx or CyberwareEx (for example VA adapters).
        if !hasCanonicalScripts {
            let module = mod.id == "equipment-ex" ? "EquipmentEx" : "CyberwareEx"
            let pattern = "(?m)^\\s*(?:module\\s+" + module + "(?:\\s|$)|(?:public\\s+)?abstract\\s+class\\s+" + module + "\\s*\\{)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let all = fm.enumerator(at: gameRoot.appendingPathComponent("r6/scripts"), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
            let detected = all.contains { value in
                guard let url = value as? URL, url.pathExtension.lowercased() == "reds",
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
            }
            guard detected else { return nil }
            return "Already present. Keep your existing install"
        }
        let manifestName = mod.package + ".json"
        let manifest = gameRoot.appendingPathComponent("red4ext/nightcity/mods/\(manifestName)")
        return fm.fileExists(atPath: manifest.path) ? "Installed" : "Already present. Keep your existing install"
    }
}
