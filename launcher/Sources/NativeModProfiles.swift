import Foundation

// Named profiles retain only immutable selected-package revisions. Mutable mod
// settings remain shared; save games and arbitrary mods are never snapshotted.
enum NativeModProfiles {
    static let path = NativeModPackages.base + "/profiles.json"
    struct Profile: Codable, Identifiable { let id: String; let name: String; let revision: String }
    struct Index: Codable { let schema: Int; let profiles: [Profile] }
    static func normalized(_ name: String) throws -> (display: String, key: String) {
        let display = name.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " _-."))
        try NativeRuntimeFiles.require(!display.isEmpty && display.utf8.count <= 80 && display.unicodeScalars.allSatisfy(allowed.contains), "Use a profile name of up to 80 bytes containing letters, numbers, spaces, hyphens or underscores.")
        return (display, display.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")))
    }
    static func read(_ root: URL) throws -> [Profile] {
        guard let data = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, path), maximum: 32 * 1024) else { return [] }
        let index = try JSONDecoder().decode(Index.self, from: data)
        try NativeRuntimeFiles.require(index.schema == 1 && index.profiles.count <= 64 && Set(index.profiles.map(\.id)).count == index.profiles.count, "Named native mod profiles are invalid.")
        for profile in index.profiles {
            let name = try normalized(profile.name)
            try NativeRuntimeFiles.require(name.display == profile.name && NativeRuntimeFiles.hash(Data(name.key.utf8)) == profile.id && NativeRuntimeFiles.digest(profile.revision), "Named profile identity is invalid.")
        }
        return index.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func write(_ profiles: [Profile], root: URL) throws {
        try NativeRuntimeFiles.write(NativeModPackages.encode(Index(schema: 1, profiles: profiles.sorted { $0.id < $1.id })), to: NativeRuntimeFiles.checked(root, path))
    }
    static func save(name: String, root: URL, gameClosed: @escaping () -> Bool) throws {
        let normalized = try normalized(name), id = NativeRuntimeFiles.hash(Data(normalized.key.utf8))
        let store = try NativeModPackages.lockStore(root, gameClosed: gameClosed)
        try store.withLaunchLock {
            try NativeModTransaction.recover(root: root)
            var profiles = try read(root)
            try NativeRuntimeFiles.require(profiles.count < 64 && !profiles.contains { $0.id == id }, "That profile name already exists, or the 64-profile limit was reached. Choose a different name.")
            let current = try NativeModPackages.readSelection(root), packages = current?.packages ?? []
            let revision = try NativeModPackages.revision(packages)
            let target = try NativeRuntimeFiles.checked(root, NativeModPackages.base + "/revisions/" + revision + ".json")
            let bytes = try NativeModPackages.encode(packages.sorted { $0.preview.packageId < $1.preview.packageId })
            if let existing = try NativeRuntimeFiles.read(target) { try NativeRuntimeFiles.require(existing == bytes, "Saved selection revision changed.") }
            else { try NativeRuntimeFiles.write(bytes, to: target) }
            profiles.append(.init(id: id, name: normalized.display, revision: revision))
            try write(profiles, root: root)
        }
    }
    static func delete(_ id: String, root: URL, gameClosed: @escaping () -> Bool) throws {
        let store = try NativeModPackages.lockStore(root, gameClosed: gameClosed)
        try store.withLaunchLock {
            let profiles = try read(root)
            try NativeRuntimeFiles.require(profiles.contains { $0.id == id }, "The named profile no longer exists.")
            try write(profiles.filter { $0.id != id }, root: root)
        }
    }
    static func apply(_ profile: Profile, root: URL, gameClosed: @escaping () -> Bool, validateScripts: () throws -> Void) throws {
        let store = try NativeModPackages.lockStore(root, gameClosed: gameClosed)
        try store.withLaunchLock {
            try NativeModTransaction.recover(root: root)
            try NativeRuntimeFiles.require(try read(root).contains { $0.id == profile.id && $0.revision == profile.revision }, "The named profile changed. Reopen the profile list.")
            let revisionURL = try NativeRuntimeFiles.checked(root, NativeModPackages.base + "/revisions/" + profile.revision + ".json")
            guard let bytes = try NativeRuntimeFiles.read(revisionURL, maximum: 2 * 1024 * 1024) else { throw NativeRuntimeError(message: "The profile's retained revision is missing.") }
            let packages = try JSONDecoder().decode([NativeModPackages.Package].self, from: bytes)
            try NativeRuntimeFiles.require(try NativeModPackages.revision(packages) == profile.revision, "The profile's retained revision changed.")
            let workspace = try NativeRuntimeFiles.checked(root, NativeModPackages.base + "/profile-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try NativeModPackages.activate(packages, current: NativeModPackages.readSelection(root), root: root, workspace: workspace, gameClosed: gameClosed, validateScripts: validateScripts)
        }
    }
}
