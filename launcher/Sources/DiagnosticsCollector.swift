import Foundation
import CryptoKit
import Darwin
import Metal
import Security

struct DiagnosticsSnapshot {
    let gameRoot: URL
    let appBundle: URL
    let appVersion: String
    let gameVersion: String?
    let installed: Bool
    let status: String
    let operationInProgress: Bool
    let native25: Bool
    let separateScriptCache: Bool
    var performanceRecordingRequested = false
    var home = FileManager.default.homeDirectoryForCurrentUser
    var temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    var includeSystemInformation = true
}

struct DiagnosticsLimits {
    var textBytes = 128 * 1024
    var totalBytes = 8 * 1024 * 1024
    var threadSampleBytes = 1024 * 1024
    var files = 80
    var directoryEntries = 4000
    var inventoryEntries = 1500
    var hashBytes = 64 * 1024 * 1024
    var totalHashBytes = 256 * 1024 * 1024
    var seconds: TimeInterval = 24
    var recentDays: TimeInterval = 7
}

struct DiagnosticsEntry {
    let name: String
    let data: Data
}

struct DiagnosticsReport {
    let entries: [DiagnosticsEntry]
    var sampleStatus = "unavailable"
    // A simple stored ZIP needs no helper process, temporary copies or shell.
    func zipData() -> Data {
        var output = Data(), directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8), size = UInt32(entry.data.count)
            let offset = UInt32(output.count), crc = Self.crc32(entry.data)
            output.u32(0x04034b50); output.u16(20); output.u16(0x800); output.u16(0)
            output.u16(0); output.u16(0x21); output.u32(crc); output.u32(size); output.u32(size)
            output.u16(UInt16(name.count)); output.u16(0); output.append(name); output.append(entry.data)
            directory.u32(0x02014b50); directory.u16(20); directory.u16(20); directory.u16(0x800)
            directory.u16(0); directory.u16(0); directory.u16(0x21); directory.u32(crc)
            directory.u32(size); directory.u32(size); directory.u16(UInt16(name.count))
            directory.u16(0); directory.u16(0); directory.u16(0); directory.u16(0)
            directory.u32(0); directory.u32(offset); directory.append(name)
        }
        let offset = UInt32(output.count)
        output.append(directory); output.u32(0x06054b50); output.u16(0); output.u16(0)
        output.u16(UInt16(entries.count)); output.u16(UInt16(entries.count))
        output.u32(UInt32(directory.count)); output.u32(offset); output.u16(0)
        return output
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320) }
        }
        return ~crc
    }
}
private extension Data {
    mutating func u16(_ value: UInt16) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}

struct DiagnosticsRedactor {
    private let replacements: [(String, String)]
    init(snapshot: DiagnosticsSnapshot) {
        replacements = [(snapshot.gameRoot.path, "<GAME>"), (snapshot.appBundle.path, "<APP>"),
                        (snapshot.home.path, "<HOME>")].sorted { $0.0.count > $1.0.count }
    }
    func text(_ input: String) -> String {
        var value = input.replacingOccurrences(of: "\\/", with: "/")
        for (path, replacement) in replacements where path.count > 1 {
            value = value.replacingOccurrences(of: path, with: replacement)
            value = value.replacingOccurrences(of: path.replacingOccurrences(of: "/", with: "\\/"), with: replacement)
        }
        // Keep useful game-relative filenames. Suppress other personal paths, identifiers,
        // addresses and credential/command lines, including those in JSON crash reports.
        let patterns: [(String, String)] = [
            (#"(?i)(?:<HOME>|/(?:Users|home|Volumes|private|tmp|var|mnt|opt|Applications))/[^\r\n\t\"<>]*"#, "<PRIVATE_PATH>"),
            (#"(?i)[A-Z]:\\(?:Users|Documents and Settings)\\[^\r\n\"]*"#, "<PRIVATE_PATH>"),
            (#"(?i)(?:userdata[/\\]|steam_?id\s*[:=]\s*)\d+"#, "<STEAM_ID>"),
            (#"\b7656119\d{10}\b"#, "<STEAM_ID>"),
            (#"[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,63}"#, "<EMAIL>"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<IP_ADDRESS>"),
            (#"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"#, "<MAC_ADDRESS>")
        ]
        for (pattern, replacement) in patterns {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return value.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            let sensitive = #"(?i)(?:\b(?:password|passwd|secret|client[_ -]?secret|private[_ -]?key|api[_ -]?key|license[_ -]?key|token|access[_ -]?token|refresh[_ -]?token|authorization|cookie|crashReporterKey|deviceIdentifierForVendor|serialNumber|machineUUID|userName|loginName)\b\"?\s*(?:=(?!=)|:(?!:))|\bbearer\s+|\b(?:queued|submitted|command[_ -]?line|environment|argv)\s*[:=]|^\s*(?:>>>|>\s))"#
            if s.range(of: sensitive, options: .regularExpression) != nil { return "[private or command line omitted]" }
            return s
        }.joined(separator: "\n")
    }
}

// Directory handles anchor reads. Each descendant component is opened with
// O_NOFOLLOW; regular-file checks reject FIFOs/devices without blocking on them.
// Only the explicitly selected root may resolve a symlink (e.g. /tmp itself).
final class DiagnosticsDirectory {
    struct Entry {
        let relative: String
        let size: Int64
        let modified: TimeInterval
        let directory: Bool
    }
    private let descriptor: Int32
    let root: URL
    init?(_ root: URL) {
        // Foundation rewrites resolved /private/tmp back to the /tmp symlink.
        // Keep POSIX realpath's actual spelling so O_NOFOLLOW works for that root.
        guard let resolved = realpath(root.path, nil) else { return nil }
        let canonical = String(cString: resolved)
        free(resolved)
        self.root = URL(fileURLWithPath: canonical, isDirectory: true)
        descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { return nil }
    }
    deinit { close(descriptor) }
    private func openRelative(_ relative: String, directory: Bool = false) -> Int32? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { return nil }
        var fd = dup(descriptor)
        guard fd >= 0 else { return nil }
        for (index, part) in parts.enumerated() {
            let isDirectory = index < parts.count - 1 || directory
            let next = openat(fd, String(part), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (isDirectory ? O_DIRECTORY : 0))
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }
    func entries(_ relative: String, limit: Int) -> [Entry] {
        guard limit > 0 else { return [] }
        let fd: Int32
        if relative.isEmpty { fd = dup(descriptor) }
        else { guard let opened = openRelative(relative, directory: true) else { return [] }; fd = opened }
        guard fd >= 0, let dir = fdopendir(fd) else { if fd >= 0 { close(fd) }; return [] }
        defer { closedir(dir) }
        var found: [Entry] = []
        var visited = 0
        while visited < limit, let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            visited += 1
            guard !name.hasPrefix("."), !name.contains("\n"), !name.contains("\r") else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { continue }
            found.append(Entry(relative: relative.isEmpty ? name : relative + "/" + name,
                               size: info.st_size, modified: Double(info.st_mtimespec.tv_sec), directory: kind == S_IFDIR))
        }
        return found
    }
    func read(_ relative: String, maximum: Int, tail: Bool = true) -> Data? {
        guard maximum > 0, let fd = openRelative(relative) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { return nil }
        let count = min(maximum, Int(clamping: info.st_size))
        if tail && info.st_size > count { guard lseek(fd, info.st_size - Int64(count), SEEK_SET) >= 0 else { return nil } }
        var bytes = [UInt8](repeating: 0, count: count)
        var used = 0
        while used < count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: used), count - used) }
            if n <= 0 { break }; used += n
        }
        return Data(bytes.prefix(used))
    }
    func information(_ relative: String) -> Entry? {
        guard let fd = openRelative(relative) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Entry(relative: relative, size: info.st_size, modified: Double(info.st_mtimespec.tv_sec), directory: false)
    }
    func hash(_ relative: String, maximum: Int, deadline: TimeInterval) -> (String, Int64)? {
        guard let fd = openRelative(relative) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { return nil }
        var hasher = SHA256(), bytes = [UInt8](repeating: 0, count: 64 * 1024), consumed = 0
        while consumed < info.st_size {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let n = Darwin.read(fd, &bytes, min(bytes.count, Int(info.st_size) - consumed))
            guard n > 0 else { return nil }
            hasher.update(data: Data(bytes.prefix(n))); consumed += n
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { return nil }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), info.st_size)
    }
}

final class DiagnosticsCollector {
    private let snapshot: DiagnosticsSnapshot
    private let limits: DiagnosticsLimits
    private let redactor: DiagnosticsRedactor
    private let deadline: TimeInterval
    private let sampleProvider: (URL, TimeInterval, Int) -> DiagnosticsProcessSample
    private var report: [DiagnosticsEntry] = []
    private var used = 0
    private var hashBytesRemaining: Int
    private var sampleMetadata: [String: Any] = ["status": "unavailable"]
    private var logIndex: [[String: Any]] = []
    private var omissions: [String] = []
    init(snapshot: DiagnosticsSnapshot, limits: DiagnosticsLimits = DiagnosticsLimits(),
         sampleProvider: @escaping (URL, TimeInterval, Int) -> DiagnosticsProcessSample = {
             DiagnosticsProcessSampler.capture(gameRoot: $0, deadline: $1, maximumBytes: $2)
         }) {
        self.snapshot = snapshot; self.limits = limits
        self.sampleProvider = sampleProvider
        hashBytesRemaining = max(0, limits.totalHashBytes)
        redactor = DiagnosticsRedactor(snapshot: snapshot)
        deadline = ProcessInfo.processInfo.systemUptime + max(0, limits.seconds)
    }
    private var hasTime: Bool { ProcessInfo.processInfo.systemUptime < deadline }
    private func add(_ name: String, _ text: String) {
        store(name, Data(redactor.text(text).utf8), truncate: true)
    }
    private func store(_ name: String, _ bytes: Data, truncate: Bool) {
        guard report.count < limits.files, used < limits.totalBytes else { return }
        let remaining = max(0, limits.totalBytes - used)
        if !truncate && bytes.count > remaining {
            omissions.append("\(name) skipped because the remaining byte budget cannot hold valid JSON.")
            return
        }
        let data = bytes.prefix(remaining)
        report.append(DiagnosticsEntry(name: name, data: Data(data))); used += data.count
    }
    private func json(_ name: String, _ value: Any) {
        let privateFields: Set<String> = ["password", "passwd", "secret", "token", "apikey", "accesstoken", "refreshtoken",
            "authorization", "cookie", "clientsecret", "privatekey", "licensekey", "crashreporterkey", "serialnumber",
            "machineuuid", "username", "loginname", "deviceidentifierforvendor", "commandline", "commands", "argv", "environment"]
        func sanitized(_ object: Any, field: String = "") -> Any {
            if let text = object as? String {
                // These fields are versions, even when a four-component value resembles an IP.
                if field.lowercased().contains("version"),
                   text.range(of: #"^[vV]?[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil { return text }
                return redactor.text(text)
            }
            if let array = object as? [Any] { return array.map { sanitized($0) } }
            if let dictionary = object as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, value) in dictionary {
                    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    if privateFields.contains(normalized) { result["private_field_omitted"] = true }
                    else { result[redactor.text(key)] = sanitized(value, field: key) }
                }
                return result
            }
            return object
        }
        if let data = try? JSONSerialization.data(withJSONObject: sanitized(value), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            store(name, data, truncate: false)
        }
    }
    func collect() -> DiagnosticsReport {
        add("README.txt", """
        NightCity Console local diagnostics. Nothing was uploaded.
        Recent log excerpts are bounded; older content may be omitted. Missing files are normal.
        Personal paths, common IDs, credential lines and console command history are excluded/redacted.
        A short thread sample of the running game in the selected folder is attempted on export only.
        process/game-process.json records the capture result, PID, times and any failure or truncation.
        No saves, screenshots, source scripts, memory dumps or unrelated process samples are included.
        Old logs and crashes may be included. Compare their dates and PIDs with the sampled process.
        Review this ZIP before sharing: mod names and text written by mods may still identify your setup.
        Signatures below are identity metadata, not a fresh Apple notarization or trust assessment.
        Frame intervals, when present, are a sample and are not a GPU benchmark.
        """)
        var summary: [String: Any] = ["schema_version": 2, "created_utc": ISO8601DateFormatter().string(from: Date()),
            "launcher_version": snapshot.appVersion, "game_version": snapshot.gameVersion ?? "unknown",
            "game_folder": "<GAME>", "game_location": snapshot.gameRoot.path.contains("/steamapps/") ? "Steam library" : "custom library",
            "external_volume": snapshot.gameRoot.path.hasPrefix("/Volumes/"), "installed": snapshot.installed,
            "status": snapshot.status, "operation_in_progress": snapshot.operationInProgress,
            "native_25": snapshot.native25, "separate_script_cache": snapshot.separateScriptCache,
            "performance_recording_requested": snapshot.performanceRecordingRequested,
            "limits": ["text_bytes_per_file": limits.textBytes, "total_text_bytes": limits.totalBytes,
                       "thread_sample_bytes": limits.threadSampleBytes, "collection_seconds": limits.seconds,
                       "max_files": limits.files, "recent_days": limits.recentDays]]
        if snapshot.includeSystemInformation { summary["system"] = Self.systemInformation(); summary["launcher_signature"] = Self.signature(snapshot.appBundle) }
        json("summary.json", summary)
        if hasTime {
            let capture = sampleProvider(snapshot.gameRoot, deadline, max(0, min(limits.threadSampleBytes, limits.totalBytes - used)))
            sampleMetadata = capture.metadata
            if let text = capture.text {
                let safe = Data(redactor.text(text).utf8)
                let maximum = max(0, min(limits.threadSampleBytes, limits.totalBytes - used - 16 * 1024))
                let clipped = safe.count > maximum
                sampleMetadata["export_text_truncated"] = clipped
                sampleMetadata["exported_text_bytes"] = min(safe.count, maximum)
                if maximum > 0 {
                    store("process/game-thread-sample.txt", Data(safe.prefix(maximum)), truncate: true)
                }
                let included = report.contains { $0.name == "process/game-thread-sample.txt" }
                sampleMetadata["sample_included"] = included
                if !included { sampleMetadata["status"] = "not_exported_budget" }
            }
        } else { sampleMetadata = ["status": "time_budget_exhausted"] }
        json("process/game-process.json", sampleMetadata)
        if hasTime, let app = DiagnosticsDirectory(snapshot.appBundle) {
            for path in ["Contents/Resources/release-inputs.json", "Contents/Resources/native25/BUILD_INFO.json"] where hasTime {
                collectBuildMetadata(app, path: path, name: "metadata/bundled-" + URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        if let game = DiagnosticsDirectory(snapshot.gameRoot) {
            collectLogs(game, directory: "red4ext/logs", prefix: "red4ext", label: "loader")
            for plugin in ["Codeware", "ArchiveXL", "TweakXL"] {
                collectLogs(game, directory: "red4ext/plugins/\(plugin)", prefix: plugin, label: plugin)
            }
            collectLogs(game, directory: "r6/logs", prefix: "redscript", label: "redscript")
            for path in ["red4ext/logs/hookstats.json", "red4ext/logs/milestones.log"] where hasTime {
                guard let info = game.information(path), recent(info),
                      let data = game.read(path, maximum: limits.textBytes, tail: !path.hasSuffix(".json")) else { continue }
                if path.hasSuffix(".json"), let object = try? JSONSerialization.jsonObject(with: data) {
                    json("logs/hookstats.json", object)
                } else {
                    add("logs/" + URL(fileURLWithPath: path).lastPathComponent + ".txt", String(decoding: data, as: UTF8.self))
                }
                logIndex.append(fileDetails(info))
            }
            collectBuildMetadata(game, path: "red4ext/BUILD_INFO.json", name: "metadata/BUILD_INFO.json")
            for path in ["red4ext/nightcity-native25.txt"] where hasTime {
                if let data = game.read(path, maximum: limits.textBytes, tail: false) {
                    add("metadata/" + URL(fileURLWithPath: path).lastPathComponent + ".txt", String(decoding: data, as: UTF8.self))
                }
            }
            collectBinaries(game)
            collectRuntimeIdentity(game)
            collectScriptIntegrity(game)
            var caches: [[String: Any]] = []
            for path in ["r6/cache/final.redscripts", "r6/cache/modded/final.redscripts", "r6/cache/final.redscripts.bk"] {
                if let info = game.information(path) { caches.append(fileDetails(info)) }
            }
            json("script-caches.json", caches)
            collectConfiguration(game)
            collectInventory(game)
        } else { omissions.append("Game folder is unavailable; game files were skipped.") }
        if hasTime, let temp = DiagnosticsDirectory(snapshot.temporaryRoot) {
            collectRuntimeStatus(temp)
            let allowed = ["cp2077_overlay.log", "cp2077_fault.log", "cp2077_binderr.log", "cp2077_bindfail.log", "cp2077_perf.json"]
            let fresh = Set((allowed + ["cp2077_out.txt"]).filter { name in
                temp.information(name).map(recent) == true
            })
            for name in allowed where hasTime && fresh.contains(name) {
                guard let info = temp.information(name), let data = temp.read(name, maximum: limits.textBytes) else { continue }
                if name == "cp2077_perf.json" {
                    if let object = try? JSONSerialization.jsonObject(with: data) {
                        json("logs/performance-summary.json", ["file_modified_utc": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: info.modified)),
                            "session_note": "Optional sample may belong to an earlier game session. Compare its recorded_at_unix and process_id with your reproduction.",
                            "sample": object])
                    }
                } else {
                    add("logs/" + name + ".txt", "File modified: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: info.modified)))\n" + String(decoding: data, as: UTF8.self))
                }
                logIndex.append(fileDetails(info))
            }
            // The console output also contains arbitrary Lua print results and commands.
            // Export only counts and known operational messages, never that history.
            if hasTime, fresh.contains("cp2077_out.txt"), let data = temp.read("cp2077_out.txt", maximum: limits.textBytes) {
                if let info = temp.information("cp2077_out.txt") { logIndex.append(fileDetails(info)) }
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                let categories: [(String, String)] = [
                    ("TweakXL is not loaded", "tweakxl_unavailable"), ("TweakXL.Reload is not registered", "tweakxl_unavailable"),
                    ("cannot find the local player", "player_unavailable"), ("not captured gameTransactionSystem", "inventory_unavailable"),
                    ("Custom weapon names are unavailable", "name_bridge_unavailable"), ("unsupported signature", "signature_mismatch"),
                    ("TweakXL did not create", "record_not_created"), ("inventory timeout", "inventory_confirmation_timeout")]
                var counts: [String: Int] = [:]
                for line in lines where line.hasPrefix("Creator: FAILED:") {
                    let category = categories.first { line.contains($0.0) }?.1 ?? "other_failure"
                    counts[category, default: 0] += 1
                }
                json("logs/console-summary.json", ["lines_inspected": lines.count, "creator_failure_categories": counts,
                    "unsupported_game_messages": lines.filter { $0.hasPrefix("NightCity Console is inactive:") }.count,
                    "command_history_and_user_output_omitted": true])
            }
        }
        collectUserDiagnostics()
        json("logs/log-index.json", logIndex)
        if !hasTime { omissions.append("Collection time budget reached; remaining optional checks skipped.") }
        add("collection.txt", "Collected \(report.count) files before this note, \(used) bytes. File, directory, age, byte and time limits apply.\n" + omissions.joined(separator: "\n"))
        return DiagnosticsReport(entries: report, sampleStatus: sampleMetadata["status"] as? String ?? "unavailable")
    }
    private func recent(_ entry: DiagnosticsDirectory.Entry) -> Bool {
        !entry.directory && entry.modified >= Date().timeIntervalSince1970 - limits.recentDays * 86400
    }
    private func fileDetails(_ entry: DiagnosticsDirectory.Entry) -> [String: Any] {
        let start = (sampleMetadata["process_start_seconds"] as? NSNumber)?.doubleValue
        return ["source": entry.relative, "original_bytes": entry.size,
                "modified_utc": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: entry.modified)),
                "modified_unix": entry.modified,
                "session_relation": start.map { entry.modified < $0 ? "predates_sampled_process" : "modified_since_process_start_not_proof_of_same_session" } ?? "unknown_no_sampled_process"]
    }
    private func collectLogs(_ root: DiagnosticsDirectory, directory: String, prefix: String, label: String) {
        guard hasTime else { return }
        let entries = root.entries(directory, limit: min(500, limits.directoryEntries))
            .filter { recent($0) && URL(fileURLWithPath: $0.relative).lastPathComponent.hasPrefix(prefix) && $0.relative.hasSuffix(".log") }
            .sorted { $0.modified > $1.modified }.prefix(2)
        for (index, entry) in entries.enumerated() where hasTime {
            let name = "logs/\(label)-\(index + 1).txt"
            let split = entry.size > limits.textBytes
            if let head = root.read(entry.relative, maximum: split ? limits.textBytes / 2 : limits.textBytes, tail: false) {
                var body = String(decoding: head, as: UTF8.self)
                if split, let tail = root.read(entry.relative, maximum: limits.textBytes / 2) {
                    body += "\n[Middle of log omitted; final excerpt follows]\n" + String(decoding: tail, as: UTF8.self)
                }
                add(name, "Source: <GAME>/\(entry.relative)\nModified: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: entry.modified)))\nOriginal bytes: \(entry.size); includes startup and final excerpts when truncated.\n" + body)
                var metadata = fileDetails(entry)
                metadata["export"] = name; metadata["truncated"] = split
                logIndex.append(metadata)
            }
        }
    }
    private func measuredHash(_ root: DiagnosticsDirectory, _ path: String) -> (String, Int64)? {
        guard hasTime, hashBytesRemaining > 0,
              let result = root.hash(path, maximum: min(limits.hashBytes, hashBytesRemaining), deadline: deadline) else { return nil }
        hashBytesRemaining -= Int(result.1)
        return result
    }
    private func comparedFile(_ root: DiagnosticsDirectory, _ path: String, bundledPath: String, app: DiagnosticsDirectory?) -> [String: Any] {
        var entry: [String: Any] = ["path": "<GAME>/" + path]
        if let info = root.information(path) { entry.merge(fileDetails(info)) { current, _ in current } }
        let installed = measuredHash(root, path)
        if let (hash, bytes) = installed { entry["sha256"] = hash; entry["bytes"] = bytes }
        else { entry["sha256"] = "unavailable or size/time limit reached" }
        if let app = app, let (hash, _) = measuredHash(app, "Contents/Resources/" + bundledPath) {
            entry["bundled_sha256"] = hash
            if let installed = installed { entry["matches_bundled"] = installed.0 == hash }
        }
        return entry
    }
    private func collectBinaries(_ root: DiagnosticsDirectory) {
        guard hasTime else { return }
        var entries: [[String: Any]] = []
        let app = DiagnosticsDirectory(snapshot.appBundle)
        let paths = ["red4ext/RED4ext.dylib", "red4ext/plugins/Codeware/Codeware.dylib", "red4ext/plugins/ArchiveXL/ArchiveXL.dylib",
                     "red4ext/plugins/TweakXL/TweakXL.dylib", "red4ext/libcyberconsole_overlay.dylib", "red4ext/FridaGadget.dylib"]
        for path in paths where hasTime {
            let native = path == "red4ext/RED4ext.dylib" || path.hasPrefix("red4ext/plugins/")
            let bundled = (native && snapshot.native25 ? "native25/" : "") + String(path.dropFirst("red4ext/".count))
            var entry = comparedFile(root, path, bundledPath: bundled, app: app)
            if snapshot.includeSystemInformation { entry["signature"] = Self.signature(root.root.appendingPathComponent(path)) }
            entries.append(entry)
        }
        json("native-binaries.json", entries)
    }
    private func collectRuntimeIdentity(_ root: DiagnosticsDirectory) {
        let app = DiagnosticsDirectory(snapshot.appBundle)
        let prefix = snapshot.native25 ? "native25/" : ""
        let paths = [("red4ext/red4ext_hooks.js", "red4ext_hooks.js"),
                     ("red4ext/FridaGadget.config", "FridaGadget.config"),
                     ("red4ext/config.ini", prefix + "config.ini"),
                     ("red4ext/" + (snapshot.native25 ? "bin/x64/" : "") + "cyberpunk2077_addresses.json", prefix + (snapshot.native25 ? "bin/x64/" : "") + "cyberpunk2077_addresses.json")]
        var entries: [[String: Any]] = []
        for (installed, bundled) in paths where hasTime {
            entries.append(comparedFile(root, installed, bundledPath: bundled, app: app))
        }
        json("runtime-files.json", entries)
    }
    private func validHash(_ value: String) -> Bool {
        value.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil
    }
    private func safeRelative(_ value: String) -> Bool {
        !value.isEmpty && value.count < 512 && !value.hasPrefix("/") &&
            !value.contains("\\") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private func collectBuildMetadata(_ root: DiagnosticsDirectory, path: String, name: String) {
        guard hasTime, let data = root.read(path, maximum: limits.textBytes, tail: false),
              let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Legacy BUILD_INFO files can contain private source paths and repository
        // pins. Export only runtime identity, never the original metadata file.
        var output: [String: Any] = ["source_provenance_omitted": true,
            "hash_note": "Build metadata may describe unsigned inputs. Compare native-binaries.json with the actual bundled files instead."]
        if let schema = source["schema"] as? Int { output["schema"] = schema }
        if let version = source["game_version"] as? String,
           version.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil { output["game_version"] = version }
        let enums: [String: Set<String>] = ["assembly_mode": ["verified-runtime-inputs"],
            "file_hash_stage": ["before-final-release-signing"], "profile": ["ui-with-verified-wardrobe", "ui-only"]]
        for (key, allowed) in enums { if let value = source[key] as? String, allowed.contains(value) { output[key] = value } }
        if let value = source["runtime_input_manifest_sha256"] as? String, validHash(value) { output["runtime_input_manifest_sha256"] = value }
        for key in ["baseline", "archivexl_bundle"] {
            if let item = source[key] as? [String: String], let hash = item["sha256"], validHash(hash),
               let version = item["version"], version.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil {
                output[key] = ["version": version, "sha256": hash]
            }
        }
        var files: [String: String] = [:]
        for (path, value) in (source["files"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }).prefix(1000) {
            guard safeRelative(path), validHash(value),
                  ["dylib", "archive", "reds", "xl", "ini", "config", "js", "dat"].contains(URL(fileURLWithPath: path).pathExtension) ||
                    (safeRelative(path) && validHash(value) && path.hasSuffix("cyberpunk2077_addresses.json")) else { continue }
            files[path] = value
        }
        output["files"] = files
        json(name, output)
    }
    private func collectScriptIntegrity(_ root: DiagnosticsDirectory) {
        let manifest = "red4ext/nightcity-plugin-scripts.json"
        guard hasTime else { return }
        guard let info = root.information(manifest), info.size <= limits.textBytes,
              let data = root.read(manifest, maximum: limits.textBytes, tail: false),
              let hashes = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            json("script-integrity.json", ["status": "manifest_missing_or_invalid", "files": []]); return
        }
        var files: [[String: Any]] = [], rejected = 0
        for (path, expected) in hashes.sorted(by: { $0.key < $1.key }).prefix(limits.inventoryEntries) {
            guard safeRelative(path), path.hasSuffix(".reds"), validHash(expected) else { rejected += 1; continue }
            let target = "r6/scripts/zz_nightcity_plugins/" + path
            var entry: [String: Any] = ["path": target, "expected_sha256": expected]
            if root.information(target) == nil { entry["status"] = "missing_or_not_regular" }
            else if let (actual, _) = measuredHash(root, target) {
                entry["actual_sha256"] = actual
                entry["status"] = actual.lowercased() == expected.lowercased() ? "matches" : "mismatch"
            } else { entry["status"] = "size_or_time_budget" }
            files.append(entry)
        }
        json("script-integrity.json", ["status": "checked", "files": files, "rejected_entries": rejected,
             "manifest_entries": hashes.count, "bounded_listing": true,
             "note": "Checks managed plugin scripts against their install manifest. No script contents are included."])
    }
    private func collectConfiguration(_ root: DiagnosticsDirectory) {
        guard hasTime else { return }
        var output: [String: Any] = [:]
        if let data = root.read("red4ext/config.ini", maximum: 32 * 1024, tail: false) {
            var section = "", values: [String: Any] = [:]
            let booleanKeys: Set<String> = ["dev.console", "dev.wait_for_debugger", "dev.strict_version_check", "plugins.enabled"]
            let numberKeys: Set<String> = ["version", "logging.max_file_size", "logging.max_files"]
            let levelKeys: Set<String> = ["logging.level", "logging.flush_on"]
            for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
                let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { continue }
                let key = (section.isEmpty ? "" : section + ".") + pair[0], value = pair[1]
                if booleanKeys.contains(key), value == "true" || value == "false" { values[key] = value == "true" }
                else if numberKeys.contains(key), let number = Int(value), (0...1_000_000).contains(number) { values[key] = number }
                else if levelKeys.contains(key), ["trace", "debug", "info", "warn", "error", "critical", "off"].contains(value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) {
                    values[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else if key == "plugins.ignored" || key == "hooking.core_hooks",
                          let bytes = value.data(using: .utf8), let items = try? JSONSerialization.jsonObject(with: bytes) as? [String] {
                    values[key + "_count"] = items.count
                    if key == "hooking.core_hooks" { values["hooking.includes_application_state"] = items.contains("CGameApplication_AddState") }
                }
            }
            output["loader"] = values
        }
        if let data = root.read("red4ext/FridaGadget.config", maximum: 32 * 1024, tail: false),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let interaction = config["interaction"] as? [String: Any] {
            var safe: [String: Any] = ["expected_script_path": interaction["path"] as? String == "./red4ext_hooks.js"]
            for (key, allowed) in ["type": ["script", "listen", "connect", "script-directory"], "on_load": ["resume", "wait"]] {
                if let value = interaction[key] as? String, allowed.contains(value) { safe[key] = value }
            }
            output["frida"] = safe
        }
        json("runtime-config.json", output)
    }
    private func collectRuntimeStatus(_ temp: DiagnosticsDirectory) {
        let path = "cp2077_runtime_diagnostics.json"
        guard let info = temp.information(path), let data = temp.read(path, maximum: 8192, tail: false),
              let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any], source["schema_version"] as? Int == 1,
              let pid = source["process_id"] as? Int, pid > 0,
              let loaded = source["script_loaded_at_unix"] as? Double, loaded.isFinite, loaded > 0,
              let updated = source["updated_at_unix"] as? Double, updated.isFinite, updated >= loaded else {
            json("logs/runtime-status.json", ["status": "missing_or_invalid"]); return
        }
        var safe: [String: Any] = ["status": "available", "schema_version": 1, "process_id": pid,
            "script_loaded_at_unix": loaded, "updated_at_unix": updated, "file": fileDetails(info)]
        let allowed: [String: [String]] = ["executor_filter": ["initializing", "native", "compatibility", "unavailable"],
            "localization_filter": ["initializing", "native", "compatibility", "unavailable"], "game_support": ["unknown", "supported", "unsupported"]]
        for (key, values) in allowed { if let value = source[key] as? String, values.contains(value) { safe[key] = value } }
        if sampleMetadata["identity_checked_before"] as? Bool == true,
           sampleMetadata["identity_checked_after"] as? Bool == true,
           let samplePID = (sampleMetadata["pid"] as? NSNumber)?.intValue,
           let start = (sampleMetadata["process_start_seconds"] as? NSNumber)?.doubleValue {
            let microseconds = (sampleMetadata["process_start_microseconds"] as? NSNumber)?.doubleValue ?? 0
            safe["session_relation"] = pid == samplePID && loaded >= start + microseconds / 1_000_000 && updated <= Date().timeIntervalSince1970 + 1 ? "matches_sampled_process" : "different_or_stale_process"
        } else { safe["session_relation"] = "unknown_identity_unconfirmed" }
        json("logs/runtime-status.json", safe)
    }
    private func collectInventory(_ root: DiagnosticsDirectory) {
        guard hasTime else { return }
        var inventory: [[String: Any]] = [], visited = 0
        let roots = ["archive/Mac/mod", "archive/pc/mod", "r6/scripts", "r6/tweaks", "red4ext/plugins"]
        var queue = roots.map { ($0, 0) }
        while !queue.isEmpty && hasTime && visited < limits.directoryEntries && inventory.count < limits.inventoryEntries {
            let (folder, depth) = queue.removeFirst()
            let entries = root.entries(folder, limit: limits.directoryEntries - visited)
            visited += entries.count
            for entry in entries {
                let leaf = URL(fileURLWithPath: entry.relative).lastPathComponent.lowercased()
                if entry.directory {
                    if depth < 5 && !["saves", "screenshots", "cache", "logs"].contains(leaf) { queue.append((entry.relative, depth + 1)) }
                } else if ["archive", "xl", "reds", "yaml", "yml", "tweak", "dylib"].contains(URL(fileURLWithPath: leaf).pathExtension) {
                    inventory.append(["path": entry.relative, "bytes": entry.size])
                }
                if inventory.count >= limits.inventoryEntries { break }
            }
        }
        json("mod-inventory.json", ["files": inventory, "bounded_listing": true, "visited_entries": visited])
    }
    private func collectUserDiagnostics() {
        guard hasTime, let home = DiagnosticsDirectory(snapshot.home) else { return }
        let crashDir = "Library/Logs/DiagnosticReports"
        let crashes = home.entries(crashDir, limit: limits.directoryEntries).filter {
            let name = URL(fileURLWithPath: $0.relative).lastPathComponent
            return recent($0) && (name.hasPrefix("Cyberpunk2077-") || name.hasPrefix("NightCityConsole-")) &&
                (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
        }.sorted { $0.modified > $1.modified }.prefix(3)
        var crashIndex: [[String: Any]] = []
        for (index, crash) in crashes.enumerated() where hasTime {
            if let data = home.read(crash.relative, maximum: limits.textBytes, tail: false) {
                let name = "crashes/report-\(index + 1).txt"
                add(name, "Recent app crash report excerpt; original bytes: \(crash.size).\nThis may be an older crash. Check its report date and PID before relating it to the current session.\n" + String(decoding: data, as: UTF8.self))
                var metadata = fileDetails(crash)
                metadata["export"] = name; metadata["truncated"] = crash.size > limits.textBytes
                crashIndex.append(metadata)
            }
        }
        json("crashes/index.json", crashIndex)
        let settings = "Library/Application Support/CD Projekt Red/Cyberpunk 2077/UserSettings.json"
        if hasTime, let data = home.read(settings, maximum: 512 * 1024, tail: false),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let groups = object["data"] as? [[String: Any]] {
            var selected: [[String: Any]] = []
            for group in groups {
                guard let name = group["group_name"] as? String, name.hasPrefix("/graphics/") || name.hasPrefix("/video/"),
                      let options = group["options"] as? [[String: Any]] else { continue }
                let values: [[String: Any]] = options.compactMap { option in
                    guard let key = option["name"] as? String, key.count < 100, let value = option["value"],
                          value is NSNumber || (value as? String).map({ $0.count < 200 }) == true else { return nil }
                    return ["name": key, "value": value]
                }
                selected.append(["group": name, "options": values])
            }
            json("graphics-settings.json", selected)
        }
    }
    private static func systemInformation() -> [String: Any] {
        func sysctlString(_ key: String) -> String {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "unknown" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unknown" }
            return String(cString: bytes)
        }
        let p = ProcessInfo.processInfo
        return ["mac_model": sysctlString("hw.model"), "cpu": sysctlString("machdep.cpu.brand_string"),
                "os": p.operatingSystemVersionString, "logical_cpus": p.processorCount,
                "active_cpus": p.activeProcessorCount, "ram_bytes": p.physicalMemory,
                "low_power_mode": p.isLowPowerModeEnabled, "thermal_state": p.thermalState.rawValue,
                "gpu_names": MTLCopyAllDevices().map(\.name)]
    }
    private static func signature(_ url: URL) -> [String: Any] {
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code = code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return ["available": false] }
        var result: [String: Any] = ["available": true]
        for (key, label) in [(kSecCodeInfoIdentifier, "identifier"), (kSecCodeInfoTeamIdentifier, "team_id"), (kSecCodeInfoFlags, "flags")] {
            if let value = info[key as String] { result[label] = value }
        }
        if let hash = info[kSecCodeInfoUnique as String] as? Data { result["cdhash"] = hash.map { String(format: "%02x", $0) }.joined() }
        return result
    }
}
