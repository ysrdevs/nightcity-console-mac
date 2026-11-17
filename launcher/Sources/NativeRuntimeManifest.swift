import Foundation
import CryptoKit
import Darwin

struct NativeRuntimeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// This is an application-owned, signed-bundle contract. Imported mod metadata
// cannot grant installation paths, native addresses or environment variables.
struct NativeRuntimeManifest: Codable {
    struct Executable: Codable {
        let relativePath: String
        let uuid: String
        // SHA-256 of the Mach-O __TEXT,__text section, unaffected by resigning.
        let textSHA256: String
    }
    struct File: Codable {
        let path: String
        let sha256: String
        let mode: Int
    }
    let schema: Int
    let backend: String
    let gameVersion: String
    let executable: Executable
    let files: [File]
    let injectedDylibs: [String]
    let scriptRoots: [String]
    let environment: [String: String]
    let previousFiles: [String: [String]]
    let retiredFiles: [String: [String]]
    let requiresPreparedPackages: Bool

    static let manifestRelative = "native20/manifest.json"
    static let runtimePath = "red4ext/plugins/NightCityRuntime/NightCityRuntime.dylib"
    static let frontendPath = "red4ext/NightCityFrontend.dylib"
    static let dataPath = "red4ext/nightcity-native20"
    static let cachePath = "r6/cache/native20/final.redscripts"

    static func load(resources: URL) throws -> (NativeRuntimeManifest, String) {
        let resourceRoot = resources.absoluteURL
        try NativeRuntimeFiles.validateRoot(resources, kind: "app resources")
        let url = try NativeRuntimeFiles.checked(resourceRoot, manifestRelative)
        guard let data = try NativeRuntimeFiles.read(url, maximum: 2 * 1024 * 1024) else {
            throw NativeRuntimeError(message: "This app is missing its native 2.5 runtime manifest. Reinstall NightCity Console; the legacy backend will not be used on 2.5.")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return (manifest, NativeRuntimeFiles.hash(data))
    }

    func validate() throws {
        try NativeRuntimeFiles.require(schema == 1 && backend == "native2.5" && gameVersion == "2.5.0", "Unsupported native runtime manifest.")
        try NativeRuntimeFiles.require(executable.relativePath == "Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" && UUID(uuidString: executable.uuid) != nil && NativeRuntimeFiles.digest(executable.textSHA256), "Invalid native game identity.")
        try NativeRuntimeFiles.require(!files.isEmpty && files.count <= 2048 && Set(files.map(\.path)).count == files.count, "Invalid native payload inventory.")
        for file in files {
            try NativeRuntimeFiles.require(Self.managedPath(file.path) && NativeRuntimeFiles.digest(file.sha256) && [0o644, 0o755].contains(file.mode), "Invalid native payload file: \(file.path)")
        }
        let paths = Set(files.map(\.path))
        let required: Set<String> = ["red4ext/RED4ext.dylib", Self.frontendPath, Self.runtimePath, "engine/tools/scc", "engine/tools/libscc_lib.dylib"]
        try NativeRuntimeFiles.require(required.isSubset(of: paths), "The native runtime payload is incomplete.")
        try NativeRuntimeFiles.require(injectedDylibs == ["red4ext/RED4ext.dylib", Self.frontendPath], "The native 2.5 injection list must contain only its loader and frontend.")
        try NativeRuntimeFiles.require(!scriptRoots.isEmpty && scriptRoots.count <= 8 && Set(scriptRoots).count == scriptRoots.count && scriptRoots.allSatisfy { root in root == "red4ext/plugins/NightCityRuntime/scripts" && paths.contains(where: { $0.hasPrefix(root + "/") }) }, "Invalid native script roots.")
        let releaseEnvironment = ["NCC_RUNTIME_PROFILE": "native20-release", "NIGHTCITY_RUNTIME_PROBE": "release20", "NCC_DISABLE_LEGACY_LUA": "1"]
        try NativeRuntimeFiles.require(environment == releaseEnvironment, "Invalid native release environment contract. Development profiles and probe hotkeys are not player payloads.")
        for (path, hashes) in previousFiles.merging(retiredFiles, uniquingKeysWith: +) {
            try NativeRuntimeFiles.require(Self.managedPath(path) && !hashes.isEmpty && hashes.count <= 32 && hashes.allSatisfy(NativeRuntimeFiles.digest), "Invalid prior payload identity: \(path)")
        }
        try NativeRuntimeFiles.require(Set(retiredFiles.keys).isDisjoint(with: paths), "A native payload file cannot also be retired.")
    }

    // Only immutable application code/data. Saves, Creator definitions, mod
    // settings, archive packs and arbitrary r6/scripts content are never owned.
    static func managedPath(_ path: String) -> Bool {
        guard NativeRuntimeFiles.relative(path) else { return false }
        if ["engine/tools/scc", "engine/tools/libscc_lib.dylib", "red4ext/RED4ext.dylib", frontendPath,
            "red4ext/config.ini", "red4ext/cet_catalog.tsv", "red4ext/red4ext_hooks.js", "red4ext/FridaGadget.dylib",
            "red4ext/FridaGadget.config", "red4ext/libcyberconsole_overlay.dylib"].contains(path) { return true }
        if path == "red4ext/bin/red4ext_plugin_check" || path.hasPrefix("red4ext/bin/x64/") { return true }
        if path.hasPrefix("r6/scripts/NightCityExploration/") && path.hasSuffix(".reds") { return true }
        guard path.hasPrefix("red4ext/plugins/") else { return false }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 4, ["NightCityRuntime", "ArchiveXL", "TweakXL", "Codeware", "input_loader", "ModSettings"].contains(components[2]) else { return false }
        let leaf = components.last!.lowercased()
        return !["settings.json", "config.json", "runtime-status.json"].contains(leaf) && !leaf.hasSuffix(".log") && !components.contains("module-data")
    }

    func verifyGame(root: URL) throws {
        let gameRoot = root.absoluteURL
        try NativeRuntimeFiles.validateRoot(root, kind: "game")
        let url = try NativeRuntimeFiles.checked(gameRoot, executable.relativePath)
        guard let bytes = try NativeRuntimeFiles.read(url, maximum: 1024 * 1024 * 1024) else { throw NativeRuntimeError(message: "Game executable is missing.") }
        let actual = try Self.imageIdentity(bytes)
        try NativeRuntimeFiles.require(actual.uuid.caseInsensitiveCompare(executable.uuid) == .orderedSame && actual.textSHA256 == executable.textSHA256,
            "This native runtime does not match the selected game executable. Only the exact supported macOS Steam 2.5 build can launch; no legacy fallback was selected.")
    }

    static func imageIdentity(_ bytes: Data) throws -> (uuid: String, textSHA256: String) {
        func word(_ offset: Int) throws -> UInt32 {
            try NativeRuntimeFiles.require(offset >= 0 && offset <= bytes.count - 4, "Truncated Mach-O image.")
            return bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        func wide(_ offset: Int) throws -> UInt64 {
            try NativeRuntimeFiles.require(offset >= 0 && offset <= bytes.count - 8, "Truncated Mach-O image.")
            return bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }
        func name(_ offset: Int) -> String { String(decoding: bytes[offset..<offset+16].prefix(while: { $0 != 0 }), as: UTF8.self) }
        try NativeRuntimeFiles.require(bytes.count >= 32 && word(0) == 0xfeedfacf && word(4) == 0x0100000c, "Expected a native arm64 Mach-O game executable.")
        let count = Int(try word(16)), size = Int(try word(20))
        try NativeRuntimeFiles.require(count <= 4096 && size <= bytes.count - 32, "Invalid Mach-O load commands.")
        var offset = 32, uuid: String?, text: String?
        for _ in 0..<count {
            let command = try word(offset), length = Int(try word(offset + 4))
            try NativeRuntimeFiles.require(length >= 8 && length <= 32 + size - offset, "Invalid Mach-O command size.")
            if command == 0x1b {
                try NativeRuntimeFiles.require(length == 24 && uuid == nil, "Invalid Mach-O UUID.")
                let hex = bytes[offset+8..<offset+24].map { String(format: "%02X", $0) }.joined()
                uuid = [String(hex.prefix(8)), String(hex.dropFirst(8).prefix(4)), String(hex.dropFirst(12).prefix(4)), String(hex.dropFirst(16).prefix(4)), String(hex.dropFirst(20))].joined(separator: "-")
            }
            if command == 0x19 {
                try NativeRuntimeFiles.require(length >= 72, "Invalid Mach-O segment.")
                let sections = Int(try word(offset + 64))
                try NativeRuntimeFiles.require(sections <= (length - 72) / 80, "Invalid Mach-O sections.")
                for index in 0..<sections {
                    let section = offset + 72 + index * 80
                    if name(section) == "__text" && name(section + 16) == "__TEXT" {
                        let start = UInt64(try word(section + 48)), length = try wide(section + 40)
                        try NativeRuntimeFiles.require(text == nil && length > 0 && start <= UInt64(bytes.count) && length <= UInt64(bytes.count) - start, "Invalid Mach-O code section.")
                        text = NativeRuntimeFiles.hash(bytes.subdata(in: Int(start)..<Int(start + length)))
                    }
                }
            }
            offset += length
        }
        try NativeRuntimeFiles.require(offset == 32 + size && uuid != nil && text != nil, "Native executable identity is incomplete.")
        return (uuid!, text!)
    }
}

enum NativeRuntimeFiles {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NativeRuntimeError(message: message) }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    static func validateRoot(_ url: URL, kind: String = "runtime") throws {
        // Bundle.main may provide a relative URL backed by the app's base URL.
        // Resolve it once, then inspect one stable decoded filesystem path.
        let absolute = url.absoluteURL
        let path = absolute.path
        let file = absolute.isFileURL, rooted = path.hasPrefix("/"), colon = path.contains(":")
        let control = path.unicodeScalars.first { CharacterSet.controlCharacters.contains($0) }
        let controlCode = control.map { String(format: "U+%04X", $0.value) } ?? "none"
        try require(file && rooted && !colon && control == nil,
            "The \(kind) folder cannot be represented safely in native launch and script arguments. A local absolute path without a colon or control character is required. [root=\(kind); scheme=\(absolute.scheme ?? "none"); file=\(file); absolute=\(rooted); colon=\(colon); control=\(controlCode); base=\(url.baseURL != nil)]")
    }
    static func relative(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 512 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.contains("\0") && !path.contains("\n") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func checked(_ root: URL, _ relative: String) throws -> URL {
        try require(self.relative(relative), "Invalid runtime path.")
        var url = root.absoluteURL.standardizedFileURL
        for part in relative.split(separator: "/") {
            url.appendPathComponent(String(part))
            var metadata = stat()
            if lstat(url.path, &metadata) == 0 {
                try require(metadata.st_mode & S_IFMT != S_IFLNK, "Linked runtime path refused: \(relative)")
                if metadata.st_mode & S_IFMT == S_IFREG { try require(metadata.st_nlink == 1, "Hard-linked runtime file refused: \(relative)") }
            } else { try require(errno == ENOENT, "Cannot inspect runtime path: \(relative)") }
        }
        return url
    }
    static func read(_ url: URL, maximum: Int = 512 * 1024 * 1024) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        try require(fd >= 0, "Cannot read \(url.lastPathComponent).")
        defer { close(fd) }
        var before = stat()
        try require(fstat(fd, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_nlink == 1 && before.st_size >= 0 && before.st_size <= maximum, "Invalid or oversized runtime file: \(url.lastPathComponent)")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while data.count <= maximum {
            let part = try handle.read(upToCount: min(1024 * 1024, maximum + 1 - data.count)) ?? Data()
            if part.isEmpty { break }
            data.append(part)
        }
        try require(data.count <= maximum, "Runtime file grew beyond its read limit.")
        var after = stat(), named = stat()
        try require(fstat(fd, &after) == 0 && lstat(url.path, &named) == 0 && before.st_dev == named.st_dev && before.st_ino == named.st_ino && before.st_size == after.st_size && after.st_size == data.count && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, "Runtime file changed while reading: \(url.lastPathComponent)")
        return data
    }
    static func write(_ bytes: Data, to url: URL, mode: Int = 0o600) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(directory >= 0, "Cannot open runtime output directory.")
        defer { close(directory) }
        let temporary = ".native-runtime-" + UUID().uuidString.lowercased()
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, "Cannot create runtime output file.")
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                try require(written > 0, "Cannot write runtime output file.")
                offset += written
            }
        }
        try require(fchmod(fd, mode_t(mode)) == 0 && fsync(fd) == 0, "Cannot sync runtime output file.")
        try require(renameat(directory, temporary, directory, url.lastPathComponent) == 0 && fsync(directory) == 0, "Cannot publish runtime output file.")
    }
}
