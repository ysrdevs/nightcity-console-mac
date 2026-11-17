import Foundation
import Darwin

enum NativeRuntimeInstallation {
    static let receiptPath = "red4ext/nightcity/native-runtime-installed.json"
    static let pendingPath = "red4ext/nightcity/native-runtime-pending.json"
    static let backupPath = "red4ext/nightcity/native-runtime-backups"
    private static let lockPath = "red4ext/nightcity/native-runtime.lock"
    struct Receipt: Codable { let schema: Int; let manifestSHA256: String; let files: [String: String] }
    struct Change: Codable { let path: String; let before: String?; let after: String?; let mode: Int; let backup: String? }
    struct Journal: Codable { let schema: Int; let id: String; let changes: [Change] }

    // UI status only. Play always performs full image and payload validation.
    static func matchingReceipt(gameRoot: URL, resources: URL) throws -> Bool {
        let (_, digest) = try NativeRuntimeManifest.load(resources: resources)
        return try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, pendingPath), maximum: 2 * 1024 * 1024) == nil && receipt(gameRoot)?.manifestSHA256 == digest
    }

    static func current(gameRoot: URL, resources: URL) throws -> Bool {
        let (manifest, digest) = try NativeRuntimeManifest.load(resources: resources)
        if try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, pendingPath), maximum: 2 * 1024 * 1024) != nil { return false }
        guard let receipt = try receipt(gameRoot), receipt.manifestSHA256 == digest && receipt.files == Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.sha256) }) else { return false }
        for file in manifest.files {
            guard let bytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, file.path)), NativeRuntimeFiles.hash(bytes) == file.sha256 else { return false }
        }
        return true
    }

    static func install(gameRoot: URL, resources: URL, gameClosed: () -> Bool, didApply: ((Int) throws -> Void)? = nil) throws {
        let (manifest, digest) = try NativeRuntimeManifest.load(resources: resources)
        try manifest.verifyGame(root: gameRoot)
        try locked(root: gameRoot) {
            try NativeRuntimeFiles.require(gameClosed(), "Quit Cyberpunk before changing the native runtime.")
            // A prior interrupted install is restored only while every changed
            // path still matches a recorded old/new hash. Foreign edits refuse.
            try recoverLocked(root: gameRoot)
            let prior = try receipt(gameRoot)
            let desired = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
            var source: [String: URL] = [:]
            for file in manifest.files {
                let url = try NativeRuntimeFiles.checked(resources, "native20/payload/" + file.path)
                guard let bytes = try NativeRuntimeFiles.read(url), NativeRuntimeFiles.hash(bytes) == file.sha256 else {
                    throw NativeRuntimeError(message: "Bundled native file is missing or damaged: \(file.path)")
                }
                source[file.path] = url
            }
            var changes: [Change] = []
            let id = UUID().uuidString.lowercased()
            let candidates = Set(desired.keys).union(prior?.files.keys.map { $0 } ?? []).union(manifest.retiredFiles.keys)
            for path in candidates.sorted() {
                try NativeRuntimeFiles.require(NativeRuntimeManifest.managedPath(path), "Invalid installed native receipt path.")
                let target = try NativeRuntimeFiles.checked(gameRoot, path)
                let existing = try NativeRuntimeFiles.read(target), before = existing.map(NativeRuntimeFiles.hash)
                let after = desired[path]?.sha256
                if before == after { continue }
                if let before {
                    let accepted = prior?.files[path] == before || manifest.previousFiles[path]?.contains(before) == true || manifest.retiredFiles[path]?.contains(before) == true
                    try NativeRuntimeFiles.require(accepted, "Kept an unrecognized or edited file: \(path). Back it up and move it outside the game folder before installing; no native files were changed.")
                }
                changes.append(Change(path: path, before: before, after: after, mode: desired[path]?.mode ?? 0o644,
                    backup: before == nil ? nil : "\(backupPath)/\(id)/\(changes.count)"))
            }
            let newReceipt = Receipt(schema: 1, manifestSHA256: digest, files: Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.sha256) }))
            let receiptBytes = try encoder().encode(newReceipt)
            let oldReceiptBytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, receiptPath), maximum: 2 * 1024 * 1024)
            changes.append(Change(path: receiptPath, before: oldReceiptBytes.map(NativeRuntimeFiles.hash), after: NativeRuntimeFiles.hash(receiptBytes), mode: 0o600,
                backup: oldReceiptBytes == nil ? nil : "\(backupPath)/\(id)/\(changes.count)"))
            // Preflight finished before any runtime file is modified.
            for change in changes {
                guard let backup = change.backup else { continue }
                guard let old = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, change.path)), NativeRuntimeFiles.hash(old) == change.before else { throw NativeRuntimeError(message: "Native files changed during installation preflight.") }
                try NativeRuntimeFiles.write(old, to: NativeRuntimeFiles.checked(gameRoot, backup))
            }
            let journal = Journal(schema: 1, id: id, changes: changes)
            try NativeRuntimeFiles.write(try encoder().encode(journal), to: NativeRuntimeFiles.checked(gameRoot, pendingPath))
            do {
                for (index, change) in changes.enumerated() {
                    try NativeRuntimeFiles.require(gameClosed(), "The game started during installation. The native changes will be restored.")
                    let target = try NativeRuntimeFiles.checked(gameRoot, change.path)
                    try NativeRuntimeFiles.require(try NativeRuntimeFiles.read(target).map(NativeRuntimeFiles.hash) == change.before, "Native file changed before replacement: \(change.path)")
                    if let expected = change.after {
                        let bytes: Data
                        if change.path == receiptPath { bytes = receiptBytes }
                        else {
                            guard let location = source[change.path], let payload = try NativeRuntimeFiles.read(location), NativeRuntimeFiles.hash(payload) == expected else { throw NativeRuntimeError(message: "Bundled native payload changed before installation.") }
                            bytes = payload
                        }
                        try NativeRuntimeFiles.write(bytes, to: target, mode: change.mode)
                    } else if change.before != nil { try FileManager.default.removeItem(at: target) }
                    try didApply?(index)
                }
                try FileManager.default.removeItem(at: NativeRuntimeFiles.checked(gameRoot, pendingPath))
            } catch {
                let failure = error
                do { try recoverLocked(root: gameRoot) }
                catch { throw NativeRuntimeError(message: "Native install stopped: \(failure.localizedDescription). Recovery also stopped: \(error.localizedDescription). Backups and the pending journal were kept; Play is blocked.") }
                throw failure
            }
        }
    }

    static func remove(gameRoot: URL, gameClosed: () -> Bool) throws {
        try locked(root: gameRoot) {
            try NativeRuntimeFiles.require(gameClosed(), "Quit Cyberpunk before removing the native runtime.")
            try recoverLocked(root: gameRoot)
            guard let prior = try receipt(gameRoot) else { return }
            let id = UUID().uuidString.lowercased()
            var changes: [Change] = []
            for (path, expected) in prior.files.sorted(by: { $0.key < $1.key }) {
                guard let bytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, path)) else { continue }
                try NativeRuntimeFiles.require(NativeRuntimeFiles.hash(bytes) == expected, "Uninstall kept an edited native file: \(path)")
                changes.append(Change(path: path, before: expected, after: nil, mode: path.hasSuffix(".dylib") || path == "engine/tools/scc" ? 0o755 : 0o644, backup: "\(backupPath)/\(id)/\(changes.count)"))
            }
            guard let receiptBytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, receiptPath)) else { throw NativeRuntimeError(message: "Native installation receipt changed during uninstall.") }
            changes.append(Change(path: receiptPath, before: NativeRuntimeFiles.hash(receiptBytes), after: nil, mode: 0o600, backup: "\(backupPath)/\(id)/\(changes.count)"))
            for change in changes {
                guard let bytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(gameRoot, change.path)), NativeRuntimeFiles.hash(bytes) == change.before else { throw NativeRuntimeError(message: "Native files changed during uninstall preflight.") }
                try NativeRuntimeFiles.write(bytes, to: NativeRuntimeFiles.checked(gameRoot, change.backup!))
            }
            try NativeRuntimeFiles.write(try encoder().encode(Journal(schema: 1, id: id, changes: changes)), to: NativeRuntimeFiles.checked(gameRoot, pendingPath))
            do {
                for change in changes {
                    try NativeRuntimeFiles.require(gameClosed(), "The game started during uninstall.")
                    let target = try NativeRuntimeFiles.checked(gameRoot, change.path)
                    try NativeRuntimeFiles.require(try NativeRuntimeFiles.read(target).map(NativeRuntimeFiles.hash) == change.before, "Native files changed before uninstall.")
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.removeItem(at: NativeRuntimeFiles.checked(gameRoot, pendingPath))
            } catch {
                let failure = error
                do { try recoverLocked(root: gameRoot) }
                catch { throw NativeRuntimeError(message: "Native uninstall and recovery stopped; backups were kept and Play is blocked: \(error.localizedDescription)") }
                throw failure
            }
        }
    }

    static func recover(gameRoot: URL, gameClosed: () -> Bool) throws {
        try locked(root: gameRoot) {
            try NativeRuntimeFiles.require(gameClosed(), "Quit Cyberpunk before recovering the native runtime.")
            try recoverLocked(root: gameRoot)
        }
    }

    private static func receipt(_ root: URL) throws -> Receipt? {
        guard let bytes = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, receiptPath), maximum: 2 * 1024 * 1024) else { return nil }
        let value = try JSONDecoder().decode(Receipt.self, from: bytes)
        try NativeRuntimeFiles.require(value.schema == 1 && NativeRuntimeFiles.digest(value.manifestSHA256) && value.files.count <= 2048 && value.files.allSatisfy { NativeRuntimeManifest.managedPath($0.key) && NativeRuntimeFiles.digest($0.value) }, "Installed native runtime receipt is invalid; existing files were preserved.")
        return value
    }
    private static func recoverLocked(root: URL) throws {
        let pending = try NativeRuntimeFiles.checked(root, pendingPath)
        guard let bytes = try NativeRuntimeFiles.read(pending, maximum: 2 * 1024 * 1024) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: bytes)
        try NativeRuntimeFiles.require(journal.schema == 1 && UUID(uuidString: journal.id) != nil && journal.changes.count <= 2049 && Set(journal.changes.map(\.path)).count == journal.changes.count, "Native recovery journal is invalid.")
        for (index, change) in journal.changes.enumerated() {
            try NativeRuntimeFiles.require((change.path == receiptPath || NativeRuntimeManifest.managedPath(change.path)) && [0o600, 0o644, 0o755].contains(change.mode) && change.before.map(NativeRuntimeFiles.digest) != false && change.after.map(NativeRuntimeFiles.digest) != false && change.backup == (change.before == nil ? nil : "\(backupPath)/\(journal.id)/\(index)"), "Native recovery contains an invalid path or identity.")
            let current = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, change.path)).map(NativeRuntimeFiles.hash)
            try NativeRuntimeFiles.require(current == change.before || current == change.after, "Recovery kept an externally changed file: \(change.path)")
            if let backup = change.backup {
                try NativeRuntimeFiles.require(try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, backup)).map(NativeRuntimeFiles.hash) == change.before, "Recovery backup is missing or changed: \(change.path)")
            }
        }
        for change in journal.changes.reversed() {
            let target = try NativeRuntimeFiles.checked(root, change.path)
            let current = try NativeRuntimeFiles.read(target).map(NativeRuntimeFiles.hash)
            if current == change.before { continue }
            try NativeRuntimeFiles.require(current == change.after, "Recovery kept a file changed during restoration: \(change.path)")
            if let backup = change.backup, let old = try NativeRuntimeFiles.read(NativeRuntimeFiles.checked(root, backup)) {
                try NativeRuntimeFiles.write(old, to: target, mode: change.path == receiptPath ? 0o600 : change.mode)
            } else if current != nil { try FileManager.default.removeItem(at: target) }
        }
        try FileManager.default.removeItem(at: pending)
    }
    private static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    private static func locked<T>(root: URL, _ body: () throws -> T) throws -> T {
        let url = try NativeRuntimeFiles.checked(root, lockPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        try NativeRuntimeFiles.require(fd >= 0, "Cannot open native runtime installation lock.")
        defer { close(fd) }
        var metadata = stat()
        try NativeRuntimeFiles.require(fstat(fd, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_nlink == 1 && flock(fd, LOCK_EX | LOCK_NB) == 0, "Another native installation or recovery is in progress.")
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
