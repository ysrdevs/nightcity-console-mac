import Foundation
import CryptoKit

struct OptionalMod: Decodable, Identifiable {
    let id: String
    let name: String
    let version: String
    let package: String
    let sha256: String
    let scriptDirectory: String

    enum CodingKeys: String, CodingKey {
        case id, name, version, package, sha256
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

    private struct Manifest: Decodable {
        let schema: Int
        let gameVersion: String
        let mods: [OptionalMod]
        enum CodingKeys: String, CodingKey {
            case schema, mods
            case gameVersion = "game_version"
        }
    }

    static func load(resources: URL?) throws -> OptionalModCatalog {
        guard let resources else { throw OptionalModError.missingCatalog }
        let root = resources.appendingPathComponent("optional-mods", isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else {
            throw OptionalModError.missingCatalog
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schema == 1, manifest.gameVersion == "2.5.0",
              Set(manifest.mods.map(\.id)) == ["equipment-ex", "cyberware-ex"], manifest.mods.count == 2 else {
            throw OptionalModError.invalidCatalog
        }
        let directories = ["equipment-ex": "r6/scripts/EquipmentEx", "cyberware-ex": "r6/scripts/CyberwareEx"]
        for mod in manifest.mods {
            guard mod.scriptDirectory == directories[mod.id],
                  mod.package == "\(mod.id)-\(mod.version).zip",
                  !mod.package.contains("/"), !mod.package.contains("\\"),
                  !mod.name.isEmpty,
                  mod.sha256.count == 64,
                  mod.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw OptionalModError.invalidCatalog
            }
        }
        return OptionalModCatalog(mods: manifest.mods, root: root)
    }

    func verifiedPackage(for mod: OptionalMod) throws -> URL {
        guard mods.contains(where: { $0.id == mod.id && $0.sha256 == mod.sha256 && $0.package == mod.package }) else {
            throw OptionalModError.invalidCatalog
        }
        let url = root.appendingPathComponent(mod.package)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true,
              let size = values?.fileSize, size > 0, size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == mod.sha256 else {
            throw OptionalModError.invalidPackage(mod.name)
        }
        return url
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
            return "Already present — keep your existing install"
        }
        let manifestName = URL(fileURLWithPath: mod.package).deletingPathExtension().lastPathComponent + ".json"
        let manifest = gameRoot.appendingPathComponent("red4ext/nightcity/mods/\(manifestName)")
        return fm.fileExists(atPath: manifest.path) ? "Installed" : "Already present — keep your existing install"
    }
}
