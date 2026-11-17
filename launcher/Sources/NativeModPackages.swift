import Foundation
import AppKit
import Darwin

// Exact original-package preparation and selected-source publication. The helper
// supplies bounded evidence; the native runtime independently grants its APIs.
enum NativeModPackages {
    static let release = "red4ext/nightcity-native20/release"
    static let base = NativeModTransaction.base
    static let activePath = base + "/active.json"
    static let ids: Set<String> = ["nativeSettings", "VehicleCallCost", "immersive_third_person", "nativeInteractions", "mansionDLC"]
    struct Summary: Identifiable { let id: String; let label: String }
    static func displayName(_ id: String) -> String {
        ["nativeSettings": "Native Settings", "VehicleCallCost": "Vehicle Call Cost", "immersive_third_person": "Immersive Third Person", "nativeInteractions": "Native Interactions", "mansionDLC": "V’s Edgerunners Mansion"][id] ?? id
    }
    static let dependencies = ["VehicleCallCost": ["nativeSettings"], "immersive_third_person": ["nativeSettings"], "mansionDLC": ["nativeInteractions"]]
    struct Configuration: Decodable { let schema: Int; let helperRelative: String; let helperSHA256: String }
    struct Dependency: Codable { let packageId: String; let requiredVersion: String; let requiredProfile: String; let status: String }
    struct Preview: Codable {
        let schema: Int, packageId: String, version: String, profileId: String, sourcePath: String
        let inventorySHA256: String, dependencies: [Dependency], mutablePolicy: String, blockers: [String]
        let preparationReady: Bool
    }
    struct Response: Decodable {
        let schema: Int, status: String, previewSHA256: String, preview: Preview
        let workspace: String?, artifactManifestPath: String?, artifactManifestSHA256: String?
        let materializationReady: Bool?
    }
    struct Artifact: Codable { let source: String; let destination: String; let size: Int64; let sha256: String; let mode: Int }
    struct Artifacts: Codable { let schema: Int; let packageId: String; let previewSHA256: String; let artifacts: [Artifact] }
    struct Package: Codable {
        let preview: Preview, previewSHA256: String, workspace: String, artifactManifestSHA256: String
        let artifacts: [Artifact]
        let companionPreviewSHA256: String?
    }
    struct Selection: Codable {
        let schema: Int, revision: String, previous: String?
        let packages: [Package]
    }
    struct Review: Identifiable {
        let id = UUID()
        let gameRoot: URL, resources: URL, expectedActive: String?, packages: [Package], selected: [Package]
        let workspace: URL
        var text: String {
            packages.map { package in
                let p = package.preview
                return "\(displayName(p.packageId)) \(p.version)\n\(package.artifacts.count) prepared files\n" +
                    (p.dependencies.isEmpty ? "No additional Lua dependency." : "Requires: " + p.dependencies.map(\.packageId).joined(separator: ", ")) +
                    "\n" + p.mutablePolicy
            }.joined(separator: "\n\n") + "\n\nExisting settings, saves, Creator definitions and unrelated mods are preserved. Changes take effect on the next launch."
        }
    }
    static func configureLaunch() {
        NativeRuntimePackagePreparation.withLaunch = { root, resources, launch in
            try withLaunch(gameRoot: root, resources: resources, launch: launch)
        }
    }
    static func configuration(_ resources: URL) throws -> (Configuration, URL) {
        guard let bytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(resources, "native20/mod-import.json"), maximum: 2 * 1024 * 1024) else {
            throw NativeRuntimeError(message: "The current native-mod preparation helper is missing from this app.")
        }
        let config = try JSONDecoder().decode(Configuration.self, from: bytes)
        try NativeRuntimeFiles.require(config.schema == 1 && config.helperRelative == "native20/helpers/NightCityModPrepare" && NativeRuntimeFiles.digest(config.helperSHA256), "Invalid native-mod preparation configuration.")
        let helper = try NativeRuntimeFiles.checked(resources, config.helperRelative)
        try NativeRuntimeFiles.require(try NativeModFiles.identity(helper)?.sha256 == config.helperSHA256, "The native-mod preparation helper differs from its signed package.")
        return (config, helper)
    }
    static func canonicalPath(_ url: URL, newChild: Bool = false) throws -> String {
        let existing = newChild ? url.deletingLastPathComponent() : url
        guard let resolved = realpath(existing.path, nil) else { throw NativeRuntimeError(message: "Cannot resolve the selected package/workspace.") }
        defer { free(resolved) }
        return String(cString: resolved) + (newChild ? "/" + url.lastPathComponent : "")
    }
    static func command(_ resources: URL, _ arguments: [String]) throws -> Response {
        let (_, helper) = try configuration(resources)
        let bytes = try NativeRuntimeCommand.run(helper, arguments: arguments, environment: NativeRuntimeLaunch.cleanEnvironment(ProcessInfo.processInfo.environment), maximumOutput: 64 * 1024, timeout: 600)
        let response = try JSONDecoder().decode(Response.self, from: bytes)
        try NativeRuntimeFiles.require(response.schema == 2 && ids.contains(response.preview.packageId) && NativeRuntimeFiles.digest(response.previewSHA256) && NativeRuntimeFiles.digest(response.preview.inventorySHA256), "Invalid current-mod preparation response.")
        return response
    }
    static func lockStore(_ root: URL, gameClosed: @escaping () -> Bool) throws -> NativePackageProfileStore {
        let directory = try NativeRuntimeFiles.checked(root, base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // This store supplies its existing descriptor-anchored transaction lock.
        // Executable package-set APIs are deliberately unused here; release
        // runtime capture validates each selected source independently.
        guard let resolved = realpath(directory.path, nil) else { throw NativeRuntimeError(message: "Cannot resolve native package storage.") }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        return try NativePackageProfileStore(root: canonical, foundation: "native-steam-2.5-release-v1",
            validateSet: { _ in throw NativeRuntimeError(message: "Executable permission cannot be granted by selection metadata.") }, isGameClosed: gameClosed)
    }
    static func readSelection(_ root: URL) throws -> Selection? {
        guard let data = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, activePath), maximum: 2 * 1024 * 1024) else { return nil }
        let selected = try JSONDecoder().decode(Selection.self, from: data)
        try validate(selected.packages)
        try NativeRuntimeFiles.require(selected.schema == 1 && NativeRuntimeFiles.digest(selected.revision) && selected.previous.map(NativeRuntimeFiles.digest) != false && selected.revision == revision(selected.packages), "The selected native-mod revision is invalid.")
        return selected
    }
    static func revision(_ packages: [Package]) throws -> String { NativeRuntimeFiles.hash(try encode(packages.sorted { $0.preview.packageId < $1.preview.packageId })) }
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    static func artifactAllowed(_ artifact: Artifact, package: String) -> Bool {
        guard NativeRuntimeFiles.relative(artifact.source), NativeRuntimeFiles.relative(artifact.destination), artifact.size >= 0, artifact.size <= NativeModFiles.limit,
              NativeRuntimeFiles.digest(artifact.sha256), [0o600, 0o644].contains(artifact.mode) else { return false }
        let path = artifact.destination
        if path.hasPrefix(release + "/packages/" + package + "/") { return true }
        if ["immersive_third_person", "nativeInteractions", "mansionDLC"].contains(package) {
            return path.hasPrefix("archive/Mac/mod/") || path.hasPrefix("r6/scripts/") || path.hasPrefix("r6/tweaks/")
        }
        return false
    }
    static func validate(_ packages: [Package]) throws {
        let selected = Set(packages.map { $0.preview.packageId })
        try NativeRuntimeFiles.require(packages.count <= ids.count && selected.count == packages.count && selected.isSubset(of: ids), "Duplicate or unsupported selected native mods.")
        var targets = Set<String>()
        for package in packages {
            try NativeRuntimeFiles.require(NativeRuntimeFiles.relative(package.workspace) && package.workspace.hasPrefix(base + "/imports/") && NativeRuntimeFiles.digest(package.previewSHA256) && NativeRuntimeFiles.digest(package.artifactManifestSHA256) && package.artifacts.count <= 512, "Invalid retained native-mod evidence.")
            try NativeRuntimeFiles.require(Set(dependencies[package.preview.packageId] ?? []).isSubset(of: selected), "Missing native mod dependency for \(package.preview.packageId).")
            for artifact in package.artifacts {
                try NativeRuntimeFiles.require(artifactAllowed(artifact, package: package.preview.packageId) && targets.insert(artifact.destination).inserted, "Duplicate or invalid mod destination: \(artifact.destination)")
            }
            if package.preview.packageId != "nativeInteractions" { try NativeRuntimeFiles.require(!package.artifacts.isEmpty, "Native mod materialization is incomplete.") }
        }
    }
    static func prepare(sources: [URL], gameRoot: URL, resources: URL, gameClosed: @escaping () -> Bool) throws -> Review? {
        _ = try configuration(resources)
        let store = try lockStore(gameRoot, gameClosed: gameClosed)
        let previous = try store.withLaunchLock { try NativeModTransaction.recover(root: gameRoot); return try readSelection(gameRoot) }
        let existing = Set(previous?.packages.map { $0.preview.packageId } ?? [])
        var identified: [Response] = []
        for source in sources {
            guard let response = try? command(resources, ["inspect-current", try canonicalPath(source), existing.sorted().joined(separator: ",")]) else {
                if identified.isEmpty { return nil }
                throw NativeRuntimeError(message: "Import native Lua packages together, separately from archive-only mods.")
            }
            identified.append(response)
        }
        guard !identified.isEmpty else { return nil }
        let incoming = Set(identified.map { $0.preview.packageId }), available = existing.union(incoming)
        try NativeRuntimeFiles.require(incoming.count == identified.count, "Select each native mod only once.")
        for response in identified { try NativeRuntimeFiles.require(Set(dependencies[response.preview.packageId] ?? []).isSubset(of: available), "Select the missing dependency with \(response.preview.packageId): \((dependencies[response.preview.packageId] ?? []).joined(separator: ", ")).") }
        let relative = base + "/imports/" + UUID().uuidString.lowercased()
        let workspace = try NativeRuntimeFiles.checked(gameRoot, relative)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var packages: [Package] = []
        for first in identified {
            let id = first.preview.packageId
            if id == "nativeInteractions" && incoming.contains("mansionDLC") { continue }
            let preview = try command(resources, ["inspect-current", first.preview.sourcePath, available.sorted().joined(separator: ",")])
            let prepared: Response, companion: Response?
            let destination = workspace.appendingPathComponent(id)
            if id == "mansionDLC" {
                guard let nif = identified.first(where: { $0.preview.packageId == "nativeInteractions" }) else { throw NativeRuntimeError(message: "Select the original Mansion and Native Interactions downloads together for preparation.") }
                companion = try command(resources, ["inspect-current", nif.preview.sourcePath])
                prepared = try command(resources, ["prepare-mansion-current", preview.preview.sourcePath, nif.preview.sourcePath, try canonicalPath(destination, newChild: true), preview.previewSHA256, companion!.previewSHA256])
            } else {
                companion = nil
                prepared = try command(resources, ["prepare-current", preview.preview.sourcePath, try canonicalPath(destination, newChild: true), preview.previewSHA256, available.sorted().joined(separator: ",")])
            }
            let package = try decodePrepared(prepared, workspace: destination, relative: relative + "/" + id, companion: companion?.previewSHA256)
            packages.append(package)
            if let companion {
                packages.append(Package(preview: companion.preview, previewSHA256: companion.previewSHA256, workspace: package.workspace,
                    artifactManifestSHA256: package.artifactManifestSHA256, artifacts: [], companionPreviewSHA256: nil))
            }
        }
        let replacing = Set(packages.map { $0.preview.packageId })
        let selected = (previous?.packages.filter { !replacing.contains($0.preview.packageId) } ?? []) + packages
        try validate(selected)
        return Review(gameRoot: gameRoot, resources: resources, expectedActive: previous?.revision, packages: packages, selected: selected, workspace: workspace)
    }
    static func decodePrepared(_ result: Response, workspace: URL, relative: String, companion: String?) throws -> Package {
        try NativeRuntimeFiles.require(result.materializationReady == true && result.preview.blockers.isEmpty, "The selected package still has unresolved materialization requirements: \(result.preview.blockers.joined(separator: "; ")).")
        try NativeRuntimeFiles.require(result.workspace == (try canonicalPath(workspace)) && result.artifactManifestPath == "artifacts.json" && result.artifactManifestSHA256.map(NativeRuntimeFiles.digest) == true,
            "The original package has not produced a complete artifact manifest.")
        guard let bytes = try NativeRuntimeFiles.read(workspace.appendingPathComponent("artifacts.json"), maximum: 256 * 1024), NativeRuntimeFiles.hash(bytes) == result.artifactManifestSHA256 else { throw NativeRuntimeError(message: "Prepared artifact manifest changed.") }
        let inventory = try JSONDecoder().decode(Artifacts.self, from: bytes)
        try NativeRuntimeFiles.require(inventory.schema == 1 && inventory.packageId == result.preview.packageId && inventory.previewSHA256 == result.previewSHA256 && !inventory.artifacts.isEmpty, "Native-mod artifacts are incomplete.")
        for artifact in inventory.artifacts {
            try NativeRuntimeFiles.require(artifactAllowed(artifact, package: inventory.packageId), "Prepared native-mod destination was refused.")
            try NativeRuntimeFiles.require(try NativeModFiles.identity(NativeRuntimeFiles.checked(workspace, artifact.source)) == .init(sha256: artifact.sha256, size: artifact.size), "Prepared native-mod bytes changed.")
        }
        return Package(preview: result.preview, previewSHA256: result.previewSHA256, workspace: relative, artifactManifestSHA256: result.artifactManifestSHA256!, artifacts: inventory.artifacts, companionPreviewSHA256: companion)
    }
    static func apply(_ review: Review, gameClosed: @escaping () -> Bool, validateScripts: () throws -> Void) throws {
        let store = try lockStore(review.gameRoot, gameClosed: gameClosed)
        try store.withLaunchLock {
            try NativeModTransaction.recover(root: review.gameRoot)
            let current = try readSelection(review.gameRoot)
            try NativeRuntimeFiles.require(current?.revision == review.expectedActive, "Selected native mods changed after preview. Prepare a new import.")
            let available = Set(review.selected.map { $0.preview.packageId }).sorted().joined(separator: ",")
            for package in review.packages where !package.artifacts.isEmpty {
                let workspace = try NativeRuntimeFiles.checked(review.gameRoot, package.workspace)
                let arguments: [String]
                if let companion = package.companionPreviewSHA256 {
                    arguments = ["verify-mansion-current", try canonicalPath(workspace), package.previewSHA256, companion]
                } else { arguments = ["verify-prepared-current", try canonicalPath(workspace), package.previewSHA256, available] }
                let verified = try command(review.resources, arguments)
                let result = try decodePrepared(verified, workspace: workspace, relative: package.workspace, companion: package.companionPreviewSHA256)
                try NativeRuntimeFiles.require(try encode(result) == encode(package), "Native-mod preparation changed after preview.")
            }
            try activate(review.selected, current: current, root: review.gameRoot, workspace: review.workspace,
                gameClosed: gameClosed, validateScripts: validateScripts)
        }
    }
    static func remove(_ packageId: String, gameRoot: URL, gameClosed: @escaping () -> Bool, validateScripts: () throws -> Void) throws {
        let store = try lockStore(gameRoot, gameClosed: gameClosed)
        try store.withLaunchLock {
            try NativeModTransaction.recover(root: gameRoot)
            guard let current = try readSelection(gameRoot), current.packages.contains(where: { $0.preview.packageId == packageId }) else { throw NativeRuntimeError(message: "That native mod is no longer selected.") }
            let requiredBy = current.packages.filter { (dependencies[$0.preview.packageId] ?? []).contains(packageId) }.map { displayName($0.preview.packageId) }
            try NativeRuntimeFiles.require(requiredBy.isEmpty, "Remove these dependent mods first: \(requiredBy.joined(separator: ", ")).")
            var removed: Set<String> = [packageId]
            if packageId == "mansionDLC", current.packages.contains(where: { $0.preview.packageId == "nativeInteractions" && $0.artifacts.isEmpty }) { removed.insert("nativeInteractions") }
            let workspace = try NativeRuntimeFiles.checked(gameRoot, base + "/remove-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try activate(current.packages.filter { !removed.contains($0.preview.packageId) }, current: current, root: gameRoot, workspace: workspace, gameClosed: gameClosed, validateScripts: validateScripts)
        }
    }
    static func restorePrevious(gameRoot: URL, gameClosed: @escaping () -> Bool, validateScripts: () throws -> Void) throws {
        let store = try lockStore(gameRoot, gameClosed: gameClosed)
        try store.withLaunchLock {
            try NativeModTransaction.recover(root: gameRoot)
            guard let current = try readSelection(gameRoot), let previous = current.previous,
                  let bytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, base + "/revisions/" + previous + ".json"), maximum: 2 * 1024 * 1024) else {
                throw NativeRuntimeError(message: "No previous native-mod selection is available.")
            }
            let packages = try JSONDecoder().decode([Package].self, from: bytes)
            try NativeRuntimeFiles.require(try revision(packages) == previous, "The previous native-mod revision changed.")
            let workspace = try NativeRuntimeFiles.checked(gameRoot, base + "/restore-" + UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try activate(packages, current: current, root: gameRoot, workspace: workspace, gameClosed: gameClosed, validateScripts: validateScripts)
        }
    }
    static func activate(_ packages: [Package], current: Selection?, root: URL, workspace: URL,
                         gameClosed: () -> Bool, validateScripts: () throws -> Void) throws {
        try validate(packages)
        let next = Selection(schema: 1, revision: try revision(packages), previous: try current?.revision ?? revision([]), packages: packages)
        var owned = [String: String](), desired = [NativeModTransaction.Desired]()
        for package in current?.packages ?? [] { for artifact in package.artifacts { owned[artifact.destination] = artifact.sha256 } }
        var selectedPaths = Set<String>()
        for package in packages { for artifact in package.artifacts {
            selectedPaths.insert(artifact.destination)
            let source = try NativeRuntimeFiles.checked(root, package.workspace + "/" + artifact.source)
            desired.append(.init(path: artifact.destination, source: source, identity: .init(sha256: artifact.sha256, size: artifact.size), mode: artifact.mode))
        } }
        for path in owned.keys where !selectedPaths.contains(path) { desired.append(.init(path: path, source: nil, identity: nil, mode: 0o600)) }
        var records: [(String, Data)] = [(base + "/revisions/" + next.revision + ".json", try encode(packages.sorted { $0.preview.packageId < $1.preview.packageId })), (activePath, try encode(next))]
        let emptyRevision = try revision([])
        if current == nil && next.revision != emptyRevision { records.insert((base + "/revisions/" + emptyRevision + ".json", try encode([Package]())), at: 0) }
        for (index, entry) in records.enumerated() {
            let source = workspace.appendingPathComponent("selection-\(index).json")
            try NativeRuntimeFiles.write(entry.1, to: source)
            let old = try NativeModFiles.identity(NativeRuntimeFiles.checked(root, entry.0))
            if entry.0 == activePath { owned[entry.0] = old?.sha256 }
            desired.append(.init(path: entry.0, source: source, identity: .init(sha256: NativeRuntimeFiles.hash(entry.1), size: Int64(entry.1.count)), mode: 0o600))
        }
        try NativeModTransaction.apply(root: root, desired: desired, owned: owned, gameClosed: gameClosed, validateStaged: validateScripts)
    }
    static func withLaunch(gameRoot: URL, resources: URL, launch: () throws -> Void) throws {
        let closed = { !NSWorkspace.shared.runningApplications.contains { $0.executableURL?.lastPathComponent == "Cyberpunk2077" } }
        let store = try lockStore(gameRoot, gameClosed: closed)
        try store.withLaunchLock {
            try NativeModTransaction.recover(root: gameRoot)
            let selection = try readSelection(gameRoot), packages = selection?.packages ?? []
            try validate(packages)
            for package in packages { for artifact in package.artifacts {
                try NativeRuntimeFiles.require(try NativeModFiles.identity(NativeRuntimeFiles.checked(gameRoot, artifact.destination)) == .init(sha256: artifact.sha256, size: artifact.size), "Selected mod file changed or is missing: \(artifact.destination). Restore the previous selection or reimport the original package.")
            } }
            let revision = try selection?.revision ?? self.revision([])
            let directory = try NativeRuntimeFiles.checked(gameRoot, release)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lock = try NativeRuntimeFiles.checked(gameRoot, release + "/release-launch.lock")
            let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            try NativeRuntimeFiles.require(fd >= 0, "Cannot open native mod startup lock."); defer { close(fd) }
            var metadata = stat()
            try NativeRuntimeFiles.require(fstat(fd, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_nlink == 1 && metadata.st_uid == getuid() && metadata.st_mode & 0o022 == 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "Native mod snapshot is being captured or its lock is invalid.")
            defer { _ = flock(fd, LOCK_UN) }
            var mask: UInt8 = 0
            for (id, bit): (String, UInt8) in [("nativeSettings", 1), ("VehicleCallCost", 2), ("immersive_third_person", 4), ("mansionDLC", 8)] {
                if packages.contains(where: { $0.preview.packageId == id }) { mask |= bit }
            }
            var bytes = Data("NCCREL1\0".utf8); bytes.append(mask); bytes.append(Data(revision.utf8))
            try NativeRuntimeFiles.require(bytes.count == 73, "Invalid native mod startup envelope.")
            try NativeRuntimeFiles.require(closed(), "The game started while preparing its mod snapshot.")
            try NativeRuntimeFiles.write(bytes, to: NativeRuntimeFiles.checked(gameRoot, release + "/release-launch.nccset"))
            // Runtime capture is synchronous after spawn and takes a shared
            // lock. Release this snapshot lock before spawning, while keeping
            // the broader selection lock through child ownership publication.
            try NativeRuntimeFiles.require(flock(fd, LOCK_UN) == 0, "Cannot release native startup snapshot lock.")
            try launch()
        }
    }
}
