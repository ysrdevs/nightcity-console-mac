import Foundation
import Darwin

struct DiagnosticsProcessSample {
    var metadata: [String: Any]
    var text: String?
}

// This collector runs on the diagnostics worker, never on the main thread. It
// samples only the selected installation's same-user executable. A process name
// is deliberately insufficient: several test installations can be open.
enum DiagnosticsProcessSampler {
    struct Identity: Equatable {
        let pid: pid_t
        let uid: uid_t
        let realUID: uid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let executablePath: String

        func sameBirth(as other: Identity) -> Bool {
            pid == other.pid && uid == other.uid && realUID == other.realUID &&
                startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
        }
    }

    // Internal seams let the tests exercise failures without ever targeting a
    // player's game. Production always uses the system process table and sample.
    struct Environment {
        var processes: () throws -> [Identity] = systemProcesses
        var identity: (pid_t) -> Identity? = systemIdentity
        var helper = URL(fileURLWithPath: "/usr/bin/sample")
        var temporaryRoot = FileManager.default.temporaryDirectory
        var maximumSeconds: TimeInterval = 10
    }

    static func capture(gameRoot: URL, deadline: TimeInterval, maximumBytes: Int,
                        durationSeconds: Int = 3) -> DiagnosticsProcessSample {
        capture(gameRoot: gameRoot, deadline: deadline, maximumBytes: maximumBytes,
                durationSeconds: durationSeconds, environment: Environment())
    }

    static func capture(gameRoot: URL, deadline: TimeInterval, maximumBytes: Int,
                        durationSeconds: Int = 3, environment: Environment) -> DiagnosticsProcessSample {
        let expected = canonical(gameRoot.appendingPathComponent("Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"))
        let duration = min(3, max(1, durationSeconds))
        let maximum = min(1024 * 1024, max(0, maximumBytes))
        let began = ProcessInfo.processInfo.systemUptime
        let stopAt = min(deadline, began + min(10, max(0, environment.maximumSeconds)))
        var metadata: [String: Any] = [
            "schema_version": 1, "status": "unavailable", "expected_executable_path": expected,
            "capture_started_utc": utc(Date()), "duration_seconds": duration,
            "interval_milliseconds": 5, "maximum_bytes": maximum,
            "identity_checked_before": false, "identity_checked_after": false
        ]
        func finish(_ status: String, _ text: String? = nil) -> DiagnosticsProcessSample {
            metadata["status"] = status
            metadata["capture_finished_utc"] = utc(Date())
            metadata["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - began
            return DiagnosticsProcessSample(metadata: metadata, text: text)
        }
        guard maximum > 0, stopAt - began >= Double(duration) + 0.25 else {
            metadata["reason"] = "Insufficient remaining diagnostics time or byte budget."
            return finish("budget_exhausted")
        }
        let matches: [Identity]
        do {
            matches = try environment.processes().filter {
                $0.pid > 0 && $0.uid == geteuid() && $0.realUID == getuid() && $0.executablePath == expected
            }
        } catch {
            metadata["reason"] = "The process table could not be read."
            return finish("unavailable")
        }
        guard matches.count == 1 else {
            metadata["matching_process_count"] = matches.count
            return finish(matches.isEmpty ? "not_running" : "ambiguous")
        }
        let target = matches[0]
        metadata["pid"] = target.pid
        metadata["executable_path"] = target.executablePath
        metadata["process_start_seconds"] = target.startSeconds
        metadata["process_start_microseconds"] = target.startMicroseconds
        metadata["process_started_utc"] = utc(Date(timeIntervalSince1970:
            Double(target.startSeconds) + Double(target.startMicroseconds) / 1_000_000))
        guard FileManager.default.isExecutableFile(atPath: environment.helper.path) else {
            metadata["reason"] = "The system sampling helper is unavailable."
            return finish("unavailable")
        }

        // mkdtemp creates a unique 0700 directory. The output is pre-created as
        // 0600 and all file access stays inside this private directory.
        var pattern = Array(environment.temporaryRoot.appendingPathComponent("nightcity-sample-XXXXXX").path.utf8CString)
        guard let directory = mkdtemp(&pattern) else {
            metadata["reason"] = "A private sampling directory could not be created."
            return finish("unavailable")
        }
        let temporary = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("sample.txt")
        let file = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard file >= 0 else { return finish("unavailable") }
        defer { close(file) }

        let standardOutput = Pipe(), standardError = Pipe()
        for pipe in [standardOutput, standardError] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        defer {
            for pipe in [standardOutput, standardError] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        let helper = Process()
        helper.executableURL = environment.helper
        helper.arguments = [String(target.pid), String(duration), "5", "-file", output.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = standardOutput
        helper.standardError = standardError
        guard stopAt - ProcessInfo.processInfo.systemUptime >= Double(duration) + 0.25 else {
            metadata["reason"] = "The diagnostics time budget expired during sampling preparation."
            return finish("budget_exhausted")
        }
        guard let before = environment.identity(target.pid) else { return finish("process_exited") }
        guard before == target else { return finish("identity_changed") }
        metadata["identity_checked_before"] = true
        do { try helper.run() }
        catch {
            metadata["reason"] = "The system sampling helper could not start."
            return finish("unavailable")
        }
        // Parent writer copies must close so EOF is observable. No blocking
        // readDataToEndOfFile/waitUntilExit is used, including on failure paths.
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
        let helperBirth = systemIdentity(helper.processIdentifier)
        var stdout = Data(), stderr = Data()
        var helperOutputTruncated = false
        var stopped: String?
        func drain() {
            helperOutputTruncated = drainPipe(standardOutput.fileHandleForReading.fileDescriptor, into: &stdout) || helperOutputTruncated
            helperOutputTruncated = drainPipe(standardError.fileHandleForReading.fileDescriptor, into: &stderr) || helperOutputTruncated
        }
        func stopOwnedHelper() {
            // Never signal the game PID. Start-time comparison also prevents a
            // stale helper PID from selecting a reused unrelated process.
            guard helper.isRunning, let birth = helperBirth,
                  let current = systemIdentity(helper.processIdentifier), current.sameBirth(as: birth) else { return }
            _ = kill(helper.processIdentifier, SIGKILL)
        }
        while helper.isRunning {
            drain()
            var info = stat()
            if fstat(file, &info) == 0, info.st_size > maximum {
                stopped = "output_limit"; break
            }
            if helperOutputTruncated { stopped = "output_limit"; break }
            if ProcessInfo.processInfo.systemUptime >= stopAt { stopped = "timed_out"; break }
            Thread.sleep(forTimeInterval: min(0.02, max(0, stopAt - ProcessInfo.processInfo.systemUptime)))
        }
        if stopped != nil { stopOwnedHelper() }
        // A terminated helper is reaped by Foundation. Never extend the caller's
        // deadline waiting for it, and never block on pipe writers it inherited.
        drain()
        if helperOutputTruncated, stopped == nil { stopped = "output_limit" }
        metadata["helper_stdout"] = boundedUTF8(stdout, maximum: 4096)
        metadata["helper_stderr"] = boundedUTF8(stderr, maximum: 4096)
        metadata["helper_output_truncated"] = helperOutputTruncated
        if !helper.isRunning { metadata["helper_exit_status"] = helper.terminationStatus }
        guard let after = environment.identity(target.pid) else { return finish("process_exited") }
        guard after == target else { return finish("identity_changed") }
        metadata["identity_checked_after"] = true

        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            return finish(stopped ?? "unavailable")
        }
        metadata["sample_bytes_written"] = info.st_size
        let truncated = info.st_size > maximum
        metadata["sample_truncated"] = truncated
        let count = min(maximum, max(0, Int(info.st_size)))
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { bytes in
            pread(file, bytes.baseAddress, count, 0)
        }
        if readCount > 0 { data.count = readCount } else { data.removeAll() }
        let sample = data.isEmpty ? nil : boundedUTF8(data, maximum: maximum)
        if let stopped { return finish(stopped, sample) }
        let helperMessages = (String(decoding: stderr, as: UTF8.self) + String(decoding: stdout, as: UTF8.self)).lowercased()
        if helperMessages.contains("permission") || helperMessages.contains("not permitted") ||
            helperMessages.contains("access denied") || helperMessages.contains("cannot attach") ||
            helperMessages.contains("unable to attach") || helperMessages.contains("task_for_pid") {
            return finish("permission_denied")
        }
        guard !helper.isRunning, helper.terminationStatus == 0, sample != nil else {
            metadata["reason"] = "The helper did not produce a successful sample."
            return finish("unavailable")
        }
        return finish(truncated ? "output_limit" : "captured", sample)
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func utc(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func boundedUTF8(_ data: Data, maximum: Int) -> String {
        // A truncated UTF-8 codepoint must not expand the exported byte budget.
        let decoded = String(decoding: data, as: UTF8.self)
        var bytes = Data(decoded.utf8.prefix(maximum))
        // Decoded is valid UTF-8, so at most three trailing bytes need removal.
        while let _ = bytes.last {
            if let value = String(data: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
    private static func drainPipe(_ fd: Int32, into result: inout Data) -> Bool {
        let maximum = 4096
        var bytes = [UInt8](repeating: 0, count: 4096)
        var overflow = false
        // Bound each pass as well as retained bytes, even for a noisy helper.
        for _ in 0..<16 {
            let count = read(fd, &bytes, bytes.count)
            if count <= 0 { break }
            let kept = min(count, max(0, maximum - result.count))
            if kept > 0 { result.append(contentsOf: bytes.prefix(kept)) }
            if kept < count { overflow = true }
        }
        return overflow
    }
    static func systemIdentity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return Identity(pid: pid, uid: info.pbi_uid, realUID: info.pbi_ruid,
                        startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
                        executablePath: canonical(URL(fileURLWithPath: String(cString: path))))
    }
    static func systemProcesses() throws -> [Identity] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0, needed < 4 * 1024 * 1024 else {
            throw NSError(domain: "DiagnosticsProcessSampler", code: 1)
        }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 1024)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, capacity)
        guard written > 0, written < capacity else {
            throw NSError(domain: "DiagnosticsProcessSampler", code: 2)
        }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).compactMap { $0 > 0 ? systemIdentity($0) : nil }
    }
}
