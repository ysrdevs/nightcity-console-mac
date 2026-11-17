import CryptoKit
import Darwin
import Foundation

struct NativePackageProfileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Private launcher storage. Inspection never changes code or mutable settings.
// validateSet MUST call the application's native reviewed-package validator for
// the complete dependency closure. JSON, filenames and hashes grant no APIs.
// Only code revisions are restored. Mutable settings live outside this store.
final class NativePackageProfileStore {
    struct Selection: Codable, Equatable {
        let schema: Int
        let active: String
        let previous: String?
    }

    struct Snapshot {
        let selection: Selection?
        let packages: [Data]
    }

    struct Inspection: Encodable, Equatable {
        enum State: String, Encodable { case absent, selected, invalid, busy, unavailable }
        struct Revision: Encodable, Equatable {
            enum Validation: String, Encodable { case valid, invalid }
            let id: String
            let validation: Validation
        }
        let state: State
        let active: Revision?
        let previous: Revision?
        init(_ state: State, active: Revision? = nil, previous: Revision? = nil) {
            self.state = state; self.active = active; self.previous = previous
        }
    }

    private struct Revision: Codable {
        let schema: Int
        let foundation: String
        let packages: [Data]
    }

    enum PublicationPoint: String {
        case revisionStaged, revisionDurable, selectionStaged, selectionPublished
    }

    static let payloadLimit = 2 * 1024 * 1024
    static let revisionLimit = 3 * 1024 * 1024
    static let revisionCountLimit = 32
    private let root: URL
    private let foundation: String
    private let validateSet: ([Data]) throws -> Void
    private let isGameClosed: () -> Bool
    private let publication: (PublicationPoint) throws -> Void

    // root is a dedicated existing directory supplied by the application, never
    // by a package. isGameClosed and validateSet are trusted application policy.
    // Selection and Play must cooperate on this same lock. The launch callback
    // below keeps it until process launch and ownership publication are complete.
    init(root: URL, foundation: String,
         validateSet: @escaping ([Data]) throws -> Void,
         isGameClosed: @escaping () -> Bool,
         publication: @escaping (PublicationPoint) throws -> Void = { _ in }) throws {
        guard root.isFileURL, root.pathComponents.first == "/",
              !root.pathComponents.contains(".."), !root.pathComponents.contains("."),
              !foundation.isEmpty, foundation.utf8.count <= 128 else {
            throw NativePackageProfileError(message: "Invalid package profile location or foundation.")
        }
        self.root = root
        self.foundation = foundation
        self.validateSet = validateSet
        self.isGameClosed = isGameClosed
        self.publication = publication
    }

    // The same lock is held for validation and the caller's spawn/publication.
    // The caller must terminate its child if ownership publication fails.
    // Preserve the shared launcher/staging lock when a private candidate uses
    // a different package store. This grants no authority to old selected code.
    func withLaunchLock<T>(_ launch: () throws -> T) throws -> T {
        try locked { directory in
            try requireClosed()
            try verifyRoot(directory)
            try requireClosed()
            return try launch()
        }
    }

    func withLaunchSnapshot<T>(_ launch: (Snapshot) throws -> T) throws -> T {
        try locked { directory in
            try requireClosed()
            let snapshot = try readSnapshot(directory)
            try verifyRoot(directory)
            try requireClosed()
            return try launch(snapshot)
        }
    }

    func snapshot() throws -> Snapshot {
        try locked { try readSnapshot($0) }
    }

    // Manual status/report reads use an existing shared lock, never create a
    // store/lock, and may run while the game is open. This is a point-in-time
    // validation of next-launch selection, not authority to launch or recover.
    // Active and previous outcomes are independent but belong to one selection.
    func inspect() -> Inspection {
        do {
            let directory = try openRoot(allowMissing: true)
            if directory < 0 { return Inspection(.absent) }
            defer { close(directory) }
            var rootMetadata = stat()
            guard fstat(directory, &rootMetadata) == 0, rootMetadata.st_uid == geteuid(),
                  rootMetadata.st_mode & 0o022 == 0 else { return Inspection(.unavailable) }
            let lock = openat(directory, "selection.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lock >= 0 else { return Inspection(.unavailable) }
            defer { close(lock) }
            var metadata = stat()
            guard fstat(lock, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1, metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else {
                return Inspection(.unavailable)
            }
            if flock(lock, LOCK_SH | LOCK_NB) != 0 {
                return Inspection(errno == EWOULDBLOCK ? .busy : .unavailable)
            }
            defer { _ = flock(lock, LOCK_UN) }
            try verifyName(directory, name: "selection.lock", metadata: metadata)
            try verifyRoot(directory)
            let before: Selection?
            do { before = try readSelection(directory) }
            catch { return Inspection(.invalid) }
            func revision(_ id: String) -> Inspection.Revision {
                do { _ = try readRevision(directory, id: id); return .init(id: id, validation: .valid) }
                catch { return .init(id: id, validation: .invalid) }
            }
            let active = before.map { revision($0.active) }
            let previous = before?.previous.map(revision)
            // A non-cooperating change must not publish mixed inspection data.
            guard try readSelection(directory) == before else { return Inspection(.unavailable) }
            try verifyName(directory, name: "selection.lock", metadata: metadata)
            try verifyRoot(directory)
            return Inspection(before == nil ? .absent : .selected, active: active, previous: previous)
        } catch { return Inspection(.unavailable) }
    }

    // A recovery preview may need the selection even when active code is
    // damaged. This result is not a validated launch snapshot.
    func recoverySelection() throws -> Selection? {
        try locked { try readSelection($0) }
    }

    // expected is the exact selection shown in the import preview. Refuse if a
    // different launcher operation changed it before the user applied the plan.
    @discardableResult
    func select(packages: [Data], expected: Selection?) throws -> Selection {
        try locked { directory in
            try requireClosed()
            let before = try readSnapshot(directory)
            try check(before.selection == expected, "The selected package revision changed after preview.")
            try validate(packages)
            let canonicalPackages = packages.sorted { Self.digest($0) < Self.digest($1) }
            let revision = Revision(schema: 1, foundation: foundation, packages: canonicalPackages)
            let encoded = try encode(revision)
            try check(encoded.count <= Self.revisionLimit, "Package revision is too large.")
            let id = Self.digest(encoded)
            let name = "r-\(id).json"
            if let existing = try read(directory, name, maximum: Self.revisionLimit, optional: true) {
                try check(existing == encoded, "An existing package revision differs.")
            } else {
                let names = try fileNames(directory)
                try check(names.filter { $0.hasPrefix("r-") }.count < Self.revisionCountLimit,
                          "Package revision storage is full; no revisions were removed.")
                try publishRevision(directory, name, bytes: encoded)
            }
            try publication(.revisionDurable)
            let selection = Selection(schema: 1, active: id, previous: before.selection?.active)
            if before.selection?.active == id { return before.selection! }
            try publish(selection, directory: directory, expected: before.selection)
            return selection
        }
    }

    @discardableResult
    func restorePrevious(expected: Selection) throws -> Selection {
        try locked { directory in
            try requireClosed()
            // Recovery must remain possible when the active revision itself is
            // corrupt or missing. The previous bytes are verified independently.
            let current = try readSelection(directory)
            try check(current == expected, "The selected package revision changed after preview.")
            guard let previous = expected.previous else {
                throw NativePackageProfileError(message: "There is no previous package revision.")
            }
            _ = try readRevision(directory, id: previous)
            let selection = Selection(schema: 1, active: previous, previous: expected.active)
            try publish(selection, directory: directory, expected: expected)
            return selection
        }
    }

    private func validate(_ packages: [Data]) throws {
        try check(!packages.isEmpty && packages.count <= 16,
                  "A package revision must contain between one and sixteen modules.")
        var size = 0
        for package in packages {
            try check(!package.isEmpty && package.count <= Self.payloadLimit,
                      "A prepared module is empty or too large.")
            size += package.count
            try check(size <= Self.payloadLimit, "Prepared modules exceed the revision size limit.")
        }
        try validateSet(packages)
    }

    private func readSnapshot(_ directory: Int32) throws -> Snapshot {
        guard let selection = try readSelection(directory) else {
            return Snapshot(selection: nil, packages: [])
        }
        let packages = try readRevision(directory, id: selection.active)
        // A corrupt previous revision must not silently authorize recovery, but
        // it does not prevent launching the independently verified active set.
        return Snapshot(selection: selection, packages: packages)
    }

    private func readSelection(_ directory: Int32) throws -> Selection? {
        guard let bytes = try read(directory, "selection.json", maximum: 1024, optional: true) else { return nil }
        let selection = try JSONDecoder().decode(Selection.self, from: bytes)
        try check(selection.schema == 1 && Self.validID(selection.active) &&
                  (selection.previous.map { Self.validID($0) && $0 != selection.active } ?? true),
                  "Invalid package selection. No revision was selected automatically.")
        return selection
    }

    private func readRevision(_ directory: Int32, id: String) throws -> [Data] {
        try check(Self.validID(id), "Invalid package revision identity.")
        guard let bytes = try read(directory, "r-\(id).json", maximum: Self.revisionLimit) else {
            throw NativePackageProfileError(message: "The selected package revision is missing.")
        }
        try check(Self.digest(bytes) == id, "Package revision bytes changed after review.")
        let revision = try JSONDecoder().decode(Revision.self, from: bytes)
        try check(revision.schema == 1 && revision.foundation == foundation,
                  "Package revision belongs to another runtime foundation.")
        try validate(revision.packages)
        return revision.packages
    }

    private func publish(_ selection: Selection, directory: Int32, expected: Selection?) throws {
        let temporary = "tmp-" + UUID().uuidString.lowercased()
        try writeNew(directory, temporary, bytes: encode(selection))
        defer { _ = unlinkat(directory, temporary, 0) }
        try publication(.selectionStaged)
        try requireClosed()
        try verifyRoot(directory)
        _ = try readRevision(directory, id: selection.active)
        try check(try readSelection(directory) == expected, "Package selection changed during publication.")
        try check(renameat(directory, temporary, directory, "selection.json") == 0,
                  "Could not publish package selection.")
        try syncDirectory(directory)
        // A thrown error after this point is not a rollback. Read snapshot() to
        // determine the committed selection instead of retrying automatically.
        try publication(.selectionPublished)
    }

    private func locked<T>(_ operation: (Int32) throws -> T) throws -> T {
        let directory = try openRoot()
        defer { close(directory) }
        let lock = openat(directory, "selection.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        try check(lock >= 0, "Cannot open the package selection lock.")
        defer { close(lock) }
        var metadata = stat()
        try check(fstat(lock, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG && metadata.st_nlink == 1,
                  "Invalid package selection lock.")
        try check(flock(lock, LOCK_EX | LOCK_NB) == 0, "Package selection or launch is already in progress.")
        defer { _ = flock(lock, LOCK_UN) }
        try verifyName(directory, name: "selection.lock", metadata: metadata)
        try verifyRoot(directory)
        return try operation(directory)
    }

    private func openRoot(allowMissing: Bool = false) throws -> Int32 {
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try check(directory >= 0, "Cannot inspect package storage.")
        do {
            let components = Array(root.pathComponents.dropFirst())
            for (index, component) in components.enumerated() {
                let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && allowMissing && index == components.count - 1 {
                    close(directory); return -1
                }
                try check(next >= 0, "Package storage is missing, linked or inaccessible at \(component): \(String(cString: strerror(errno)))")
                close(directory)
                directory = next
            }
            return directory
        } catch { close(directory); throw error }
    }

    private func verifyRoot(_ directory: Int32) throws {
        let current = try openRoot()
        defer { close(current) }
        var a = stat(), b = stat()
        try check(fstat(directory, &a) == 0 && fstat(current, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino,
                  "Package storage changed during the operation.")
    }

    private func read(_ directory: Int32, _ name: String, maximum: Int, optional: Bool = false) throws -> Data? {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 && errno == ENOENT && optional { return nil }
        try check(file >= 0, "Cannot read package storage file: \(name)")
        defer { close(file) }
        var before = stat()
        try check(fstat(file, &before) == 0 && (before.st_mode & S_IFMT) == S_IFREG && before.st_nlink == 1 &&
                  before.st_size > 0 && before.st_size <= maximum, "Invalid package storage file: \(name)")
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size) + 1)
        var count = 0
        while count < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(file, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if amount < 0 && errno == EINTR { continue }
            try check(amount >= 0, "Cannot read package storage file: \(name)")
            if amount == 0 { break }
            count += amount
        }
        var after = stat()
        try check(fstat(file, &after) == 0 && count == before.st_size && after.st_size == before.st_size &&
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec &&
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec &&
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec &&
                  after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                  "Package storage file changed during the read: \(name)")
        try verifyName(directory, name: name, metadata: after)
        return Data(bytes.prefix(count))
    }

    private func verifyName(_ directory: Int32, name: String, metadata: stat) throws {
        var named = stat()
        try check(fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && named.st_dev == metadata.st_dev &&
                  named.st_ino == metadata.st_ino && named.st_nlink == 1 && (named.st_mode & S_IFMT) == S_IFREG,
                  "Package storage file was replaced: \(name)")
    }

    private func writeNew(_ directory: Int32, _ name: String, bytes: Data) throws {
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try check(file >= 0, "Cannot create package storage file: \(name)")
        defer { close(file) }
        var completed = false
        defer { if !completed { _ = unlinkat(directory, name, 0) } }
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let amount = Darwin.write(file, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if amount < 0 && errno == EINTR { continue }
                try check(amount > 0, "Cannot write package storage file: \(name)")
                written += amount
            }
        }
        try check(fcntl(file, F_FULLFSYNC) == 0, "Cannot durably write package storage file: \(name)")
        try syncDirectory(directory)
        completed = true
    }

    private func publishRevision(_ directory: Int32, _ name: String, bytes: Data) throws {
        let temporary = "tmp-" + UUID().uuidString.lowercased()
        try writeNew(directory, temporary, bytes: bytes)
        defer { _ = unlinkat(directory, temporary, 0) }
        try publication(.revisionStaged)
        // RENAME_EXCL never replaces an existing immutable revision. A process
        // interruption during the write can leave only an unselected temporary.
        try check(renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0,
                  "Cannot publish immutable package revision.")
        try syncDirectory(directory)
    }

    private func fileNames(_ directory: Int32) throws -> [String] {
        let copy = dup(directory)
        try check(copy >= 0, "Cannot inspect package revision quota.")
        guard let stream = fdopendir(copy) else { close(copy); throw NativePackageProfileError(message: "Cannot list package revisions.") }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            try check(names.count <= 128, "Package revision storage contains too many files; no files were removed.")
            errno = 0
        }
        try check(errno == 0, "Cannot finish listing package revisions.")
        return names
    }

    private func syncDirectory(_ directory: Int32) throws {
        try check(fsync(directory) == 0, "Cannot durably publish package storage changes.")
    }

    private func requireClosed() throws {
        try check(isGameClosed(), "Close the game before changing or launching a package profile.")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativePackageProfileError(message: message) }
    }
}
