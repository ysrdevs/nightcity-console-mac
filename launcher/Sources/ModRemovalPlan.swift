import Foundation
import Darwin

// Validate the complete receipt before the caller unlinks anything. Legacy
// receipts contain absolute paths, which may still refer to a different game.
enum ModRemovalPlan {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static let foundations: Set<String> = ["codeware", "archivexl", "tweakxl", "modsettings", "mod_settings", "input_loader", "inputloader", "red4ext", "redscript", "nightcity", "nightcityconsole", "nightcityexploration", "zz_nightcity_plugins"]
    private static func folded(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func fail(_ message: String) throws -> Never { throw Failure(message: "Cannot safely remove this mod: " + message) }
    private static func parts(_ path: String, absolute: Bool) throws -> [String] {
        guard path.hasPrefix("/") == absolute, path.utf8.count <= 4096,
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { try fail("invalid file path.") }
        let values = (absolute ? String(path.dropFirst()) : path).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !values.isEmpty, values.count <= 64, values.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { try fail("invalid file path.") }
        return values
    }
    private static func metadata(_ path: String) throws -> stat? {
        var value = stat()
        if lstat(path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        try fail("a path could not be inspected: \(path)")
    }
    // Compare directory identity instead of textual prefixes. This permits the
    // system /var alias and case/Unicode aliases without following links below
    // the selected game root.
    private static func relative(_ path: String, root: URL, identity: stat) throws -> String {
        let values = try parts(path, absolute: true)
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, part) in values.enumerated() {
            cursor.appendPathComponent(part)
            var candidate = stat()
            if stat(cursor.path, &candidate) == 0,
               candidate.st_dev == identity.st_dev, candidate.st_ino == identity.st_ino {
                guard index + 1 < values.count else { try fail("the game root cannot be removed.") }
                return values.dropFirst(index + 1).joined(separator: "/")
            }
        }
        try fail("the receipt refers to a different game folder: \(path)")
    }
    private static func checked(_ relative: String, root: URL) throws -> URL? {
        let values = try parts(relative, absolute: false)
        var cursor = root
        for (index, part) in values.enumerated() {
            cursor.appendPathComponent(part)
            guard let info = try metadata(cursor.path) else { return nil }
            let wanted = index == values.count - 1 ? S_IFREG : S_IFDIR
            guard info.st_mode & S_IFMT == wanted else { try fail("linked, special or non-file path: \(relative)") }
        }
        return cursor
    }
    private static func read(_ relative: String, root: URL, required: Bool = false) throws -> Data? {
        guard let url = try checked(relative, root: root) else {
            if required { try fail("the installation receipt is missing.") }
            return nil
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { try fail("a manifest could not be opened safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 16 * 1024 * 1024 else { try fail("a manifest is not a bounded regular file.") }
        let data = try handle.read(upToCount: Int(info.st_size) + 1) ?? Data()
        guard data.count == info.st_size else { try fail("a manifest changed while it was read.") }
        return data
    }
    private static func foundation(_ name: String) -> Bool {
        foundations.contains(name) || foundations.contains { name.hasPrefix($0 + ".") }
    }
    private static func supported(_ relative: String) -> Bool {
        let path = folded(relative), components = path.split(separator: "/").map(String.init)
        let name = components.last ?? "", ext = (name as NSString).pathExtension
        if ["dll", "dylib", "so", "exe", "asi", "bundle", "lua"].contains(ext) { return false }
        if ["ncccollisionflightprobe.reds", "nccflightclearance.reds"].contains(name) { return false }
        if path.hasPrefix("archive/mac/mod/") { return ["archive", "xl"].contains(ext) && !foundation(name) }
        if path.hasPrefix("r6/scripts/") { return components.count >= 3 && !foundation(components[2]) }
        if path.hasPrefix("r6/tweaks/") { return !name.hasPrefix("cybermodman_") }
        if path.hasPrefix("r6/input/") { return components.count >= 3 && !foundation(components[2]) }
        if path.hasPrefix("r6/config/redsuserhints/") { return true }
        if path.hasPrefix("red4ext/plugins/archivexl/bundle/") { return components.count == 5 && ext == "xl" && !foundation(name) }
        if path.hasPrefix("red4ext/plugins/"), components.count >= 4 {
            return !foundation(components[2]) && ["json", "ini", "toml", "yaml", "yml", "xml", "xl"].contains(ext)
        }
        return false
    }
    private static func managedFiles(root: URL) throws -> Set<String> {
        var managed = Set<String>()
        if let data = try read("red4ext/nightcity-native25.txt", root: root) {
            guard let text = String(data: data, encoding: .utf8) else { try fail("the native runtime manifest is invalid.") }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard fields.count == 2, fields[0].count == 64, fields[0].allSatisfy({ "0123456789abcdef".contains($0) }) else { try fail("the native runtime manifest is invalid.") }
                let path = String(fields[1]).trimmingCharacters(in: .whitespaces)
                _ = try parts(path, absolute: false)
                managed.insert(folded("red4ext/" + path))
            }
        }
        if let data = try read("red4ext/nightcity-exploration.json", root: root) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schema"] as? Int == 1, let files = object["files"] as? [String: String] else { try fail("the exploration manifest is invalid.") }
            for (name, hash) in files {
                _ = try parts(name, absolute: false)
                guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { try fail("the exploration manifest is invalid.") }
                managed.insert(folded("r6/scripts/NightCityExploration/" + name))
            }
        }
        return managed
    }

    static func validatedFiles(manifest: URL, gameRoot: URL) throws -> [URL] {
        guard manifest.isFileURL, gameRoot.isFileURL else { try fail("local file paths are required.") }
        let root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let identity = try metadata(root.path), identity.st_mode & S_IFMT == S_IFDIR else { try fail("the selected game folder is missing.") }
        let receipt = try relative(manifest.path, root: root, identity: identity)
        let receiptParts = receipt.split(separator: "/").map(String.init)
        guard receiptParts.count == 4, receiptParts.prefix(3).map(folded) == ["red4ext", "nightcity", "mods"],
              receiptParts[3].lowercased().hasSuffix(".json") else { try fail("the receipt is outside NightCity's installed mod list.") }
        let data = try read(receipt, root: root, required: true)!
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [String], files.count <= 20000 else { try fail("the receipt file list is invalid.") }
        let managed = try managedFiles(root: root)
        var result = [URL](), seen = Set<String>()
        for path in files {
            let rel = try relative(path, root: root, identity: identity)
            guard supported(rel), !managed.contains(folded(rel)) else { try fail("the receipt includes a protected or unsupported file: \(rel)") }
            // Missing files are harmless; an unsafe missing path still failed
            // containment/protection above. Validate all entries before returning.
            if let url = try checked(rel, root: root), seen.insert(folded(rel)).inserted { result.append(url) }
        }
        return result
    }
}
