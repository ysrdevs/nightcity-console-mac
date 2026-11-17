import Foundation
import CryptoKit
import Darwin

// Streaming file operations for original archive packs. No archive-sized Data
// allocation; every source and destination is checked before publication.
enum NativeModFiles {
    static let limit: Int64 = 2 * 1024 * 1024 * 1024
    struct Identity: Equatable { let sha256: String; let size: Int64 }
    static func identity(_ url: URL) throws -> Identity? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        try NativeRuntimeFiles.require(fd >= 0, "Cannot inspect mod file: \(url.lastPathComponent)")
        defer { close(fd) }
        var before = stat()
        try NativeRuntimeFiles.require(fstat(fd, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_nlink == 1 && before.st_size >= 0 && before.st_size <= limit, "Unsupported mod file or link: \(url.lastPathComponent)")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256(), size: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            size += Int64(data.count); try NativeRuntimeFiles.require(size <= limit && size <= before.st_size, "Mod file grew during inspection.")
            hash.update(data: data)
        }
        var after = stat(), named = stat()
        try NativeRuntimeFiles.require(fstat(fd, &after) == 0 && lstat(url.path, &named) == 0 && before.st_dev == named.st_dev && before.st_ino == named.st_ino && before.st_size == size && after.st_size == size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, "Mod file changed while inspecting it.")
        return .init(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), size: size)
    }
    static func copy(_ source: URL, to target: URL, expected: Identity, mode: Int = 0o600) throws {
        try NativeRuntimeFiles.require(try identity(source) == expected, "Prepared mod file changed before copying.")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".nightcity-mod-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try NativeRuntimeFiles.require(try identity(temporary) == expected && identity(source) == expected, "Prepared mod file changed while copying.")
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try NativeRuntimeFiles.require(fd >= 0, "Cannot sync the staged mod file.")
        defer { close(fd) }
        try NativeRuntimeFiles.require(fchmod(fd, mode_t(mode)) == 0 && fsync(fd) == 0, "Cannot sync the staged mod file.")
        try NativeRuntimeFiles.require(rename(temporary.path, target.path) == 0, "Cannot publish the staged mod file.")
        try sync(target.deletingLastPathComponent())
    }
    static func remove(_ url: URL) throws {
        try NativeRuntimeFiles.require(unlink(url.path) == 0 || errno == ENOENT, "Cannot remove owned mod file.")
        try sync(url.deletingLastPathComponent())
    }
    static func sync(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try NativeRuntimeFiles.require(fd >= 0, "Cannot sync mod directory."); defer { close(fd) }
        try NativeRuntimeFiles.require(fsync(fd) == 0, "Cannot sync mod directory.")
    }
}

// Caller holds NativePackageProfileStore's closed-game lock for both Apply and
// launch. Journal publication precedes the first write, including selection.
enum NativeModTransaction {
    static let base = "red4ext/nightcity-native20/package-state"
    static let pending = base + "/pending.json"
    struct Desired { let path: String; let source: URL?; let identity: NativeModFiles.Identity?; let mode: Int }
    struct Change: Codable {
        let path: String, backup: String?
        let before: String?, after: String?
        let beforeSize: Int64?, afterSize: Int64?
        let beforeMode: Int?, mode: Int
    }
    struct Journal: Codable { let schema: Int; let id: String; let changes: [Change] }
    static func allowed(_ path: String) -> Bool {
        guard NativeRuntimeFiles.relative(path) else { return false }
        if path == base + "/active.json" || path.hasPrefix(base + "/revisions/") { return true }
        if path.hasPrefix("red4ext/nightcity-native20/release/packages/") { return true }
        return path.hasPrefix("archive/Mac/mod/") || path.hasPrefix("r6/scripts/") || path.hasPrefix("r6/tweaks/")
    }
    static func apply(root: URL, desired: [Desired], owned: [String: String], gameClosed: () -> Bool, validateStaged: () throws -> Void = {}, didApply: ((Int) throws -> Void)? = nil) throws {
        try NativeRuntimeFiles.require(gameClosed(), "Close Cyberpunk before applying mods.")
        try recover(root: root)
        try NativeRuntimeFiles.require(desired.count <= 1024 && Set(desired.map(\.path)).count == desired.count, "Invalid or duplicate mod destinations.")
        let id = UUID().uuidString.lowercased(); var changes: [Change] = []; var sources: [String: URL] = [:]
        let ordered = desired.sorted { a, b in
            let am = a.path == base + "/active.json" ? 2 : a.path.hasPrefix(base + "/revisions/") ? 1 : 0
            let bm = b.path == base + "/active.json" ? 2 : b.path.hasPrefix(base + "/revisions/") ? 1 : 0
            return am == bm ? a.path < b.path : am < bm
        }
        for item in ordered {
            try NativeRuntimeFiles.require(allowed(item.path) && [0o600, 0o644, 0o755].contains(item.mode), "Unsupported mod destination.")
            let target = try NativeRuntimeFiles.checked(root, item.path), before = try NativeModFiles.identity(target)
            if let identity = item.identity {
                guard let source = item.source else { throw NativeRuntimeError(message: "Prepared mod source is missing.") }
                try NativeRuntimeFiles.require(try NativeModFiles.identity(source) == identity, "Prepared mod artifact changed.")
                sources[item.path] = source
            } else { try NativeRuntimeFiles.require(item.source == nil, "Invalid mod removal.") }
            if before == item.identity { continue }
            if let before { try NativeRuntimeFiles.require(owned[item.path] == before.sha256, "Kept unowned or edited mod file: \(item.path)") }
            let permissions = before == nil ? nil : (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
            changes.append(.init(path: item.path, backup: before == nil ? nil : "\(base)/backups/\(id)/\(changes.count)", before: before?.sha256, after: item.identity?.sha256, beforeSize: before?.size, afterSize: item.identity?.size, beforeMode: permissions, mode: item.mode))
        }
        for change in changes { if let backup = change.backup {
            try NativeModFiles.copy(NativeRuntimeFiles.checked(root, change.path), to: NativeRuntimeFiles.checked(root, backup), expected: .init(sha256: change.before!, size: change.beforeSize!))
        } }
        let journal = Journal(schema: 1, id: id, changes: changes)
        try NativeRuntimeFiles.write(JSONEncoder().encode(journal), to: NativeRuntimeFiles.checked(root, pending))
        do {
            var validated = false
            for (index, change) in changes.enumerated() {
                if change.path.hasPrefix(base + "/") && !validated { try validateStaged(); validated = true }
                try NativeRuntimeFiles.require(gameClosed(), "The game started during mod installation.")
                let target = try NativeRuntimeFiles.checked(root, change.path)
                try NativeRuntimeFiles.require(try NativeModFiles.identity(target)?.sha256 == change.before, "A mod file changed before publication.")
                if let source = sources[change.path] {
                    try NativeModFiles.copy(source, to: target, expected: .init(sha256: change.after!, size: change.afterSize!), mode: change.mode)
                } else { try NativeModFiles.remove(target) }
                try didApply?(index)
            }
            if !validated { try validateStaged() }
            try NativeModFiles.remove(NativeRuntimeFiles.checked(root, pending))
        } catch {
            let failure = error
            do { try recover(root: root) }
            catch { throw NativeRuntimeError(message: "Mod installation and recovery stopped. Existing evidence was kept and Play is blocked: \(error.localizedDescription)") }
            throw failure
        }
    }
    static func recover(root: URL) throws {
        guard let bytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, pending), maximum: 4 * 1024 * 1024) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: bytes)
        try NativeRuntimeFiles.require(journal.schema == 1 && UUID(uuidString: journal.id) != nil && journal.changes.count <= 1024 && Set(journal.changes.map(\.path)).count == journal.changes.count, "Invalid native mod recovery journal.")
        for (index, change) in journal.changes.enumerated() {
            try NativeRuntimeFiles.require(allowed(change.path) && change.before.map(NativeRuntimeFiles.digest) != false && change.after.map(NativeRuntimeFiles.digest) != false && change.backup == (change.before == nil ? nil : "\(base)/backups/\(journal.id)/\(index)"), "Invalid native mod recovery path.")
            let current = try NativeModFiles.identity(NativeRuntimeFiles.checked(root, change.path))?.sha256
            try NativeRuntimeFiles.require(current == change.before || current == change.after, "Recovery preserved a changed mod file: \(change.path)")
            if let backup = change.backup {
                try NativeRuntimeFiles.require(change.beforeSize != nil && change.beforeSize! >= 0 && change.beforeSize! <= NativeModFiles.limit && (0...0o777).contains(change.beforeMode ?? change.mode), "Invalid native mod backup metadata.")
                try NativeRuntimeFiles.require(try NativeModFiles.identity(NativeRuntimeFiles.checked(root, backup)) == .init(sha256: change.before!, size: change.beforeSize!), "Native mod recovery backup changed.")
            }
        }
        for change in journal.changes.reversed() {
            let target = try NativeRuntimeFiles.checked(root, change.path), current = try NativeModFiles.identity(target)?.sha256
            if current == change.before { continue }
            try NativeRuntimeFiles.require(current == change.after, "Recovery kept a concurrently edited mod file.")
            if let backup = change.backup {
                try NativeModFiles.copy(NativeRuntimeFiles.checked(root, backup), to: target, expected: .init(sha256: change.before!, size: change.beforeSize!), mode: change.beforeMode ?? change.mode)
            } else { try NativeModFiles.remove(target) }
        }
        try NativeModFiles.remove(NativeRuntimeFiles.checked(root, pending))
    }
}
