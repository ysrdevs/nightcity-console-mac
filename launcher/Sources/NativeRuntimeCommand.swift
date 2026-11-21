import Foundation
import Darwin

// Preparation tools own a separate process group. Failures never turn an
// unknown child status into success, and retain bounded support evidence.
enum NativeRuntimeCommand {
    struct SystemCalls {
        var poll: (UnsafeMutablePointer<pollfd>, nfds_t, Int32) -> Int32 = { Darwin.poll($0, $1, $2) }
        var read: (Int32, UnsafeMutableRawPointer?, Int) -> Int = { Darwin.read($0, $1, $2) }
        var wait: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { Darwin.waitpid($0, $1, $2) }
    }
    private static let logLock = NSLock()
    private static func phase(tool: String, arguments: [String]) -> String {
        if tool == "scc" { return "compile" }
        if tool == "red4ext_plugin_check" { return "verify-plugins" }
        let known = ["compat25", "regen", "prepare-import", "commit-import", "stageplugins"]
        return arguments.first.flatMap { known.contains($0) ? $0 : nil } ?? "prepare"
    }
    private static func record(directory: URL?, tool: String, record: [String: Any]) {
        guard let directory, ["nctool", "scc", "red4ext_plugin_check"].contains(tool) else { return }
        logLock.lock(); defer { logLock.unlock() }
        do {
            let logs = try NativeRuntimeFiles.checked(directory, NativeRuntimeManifest.dataPath + "/logs")
            let path = try NativeRuntimeFiles.checked(directory, NativeRuntimeManifest.dataPath + "/logs/preparation-" + UUID().uuidString.lowercased() + ".log")
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try NativeRuntimeFiles.require(bytes.count <= 128 * 1024, "Preparation record exceeded its bound.")
            try NativeRuntimeFiles.write(bytes, to: path)
            let candidates = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { url in
                    let name = url.lastPathComponent
                    guard name.hasPrefix("preparation-"), name.hasSuffix(".log"), UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil else { return false }
                    var info = stat()
                    return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == getuid()
                }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            for old in candidates.dropFirst(16) { try? FileManager.default.removeItem(at: old) }
        } catch { /* A diagnostic write must not change tool success/failure. */ }
    }
    static func run(_ executable: URL, arguments: [String], directory: URL? = nil,
                    environment: [String: String], maximumOutput: Int = 256 * 1024, timeout: TimeInterval = 120,
                    systemCalls: SystemCalls = SystemCalls()) throws -> Data {
        let began = ProcessInfo.processInfo.systemUptime, started = ISO8601DateFormatter().string(from: Date())
        let tool = executable.lastPathComponent, operation = phase(tool: executable.lastPathComponent, arguments: arguments)
        var pid: pid_t = 0, status: Int32 = 0, observedStatus: Int32?, waitError: Int32?
        var output = Data(), outcome = "setup_failed", failure = ""
        defer {
            func redacted(_ text: String) -> String {
                var value = text
                if let directory { value = value.replacingOccurrences(of: directory.path, with: "<GAME>") }
                return value.replacingOccurrences(of: NSHomeDirectory(), with: "<HOME>")
            }
            record(directory: directory, tool: tool, record: [
                "schema": 1, "started_utc": started, "finished_utc": ISO8601DateFormatter().string(from: Date()),
                "tool": tool, "phase": operation, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began,
                "timeout_seconds": timeout, "pid": pid, "outcome": outcome,
                "wait_status": observedStatus.map { $0 as Any } ?? NSNull(),
                "wait_errno": waitError.map { $0 as Any } ?? NSNull(),
                "output_bytes": output.count, "output_truncated": output.count > 16384,
                "output_tail": redacted(String(decoding: output.suffix(16384), as: UTF8.self)),
                "error": redacted(failure)
            ])
        }
        func fail(_ reason: String, outcome result: String) throws -> Never {
            outcome = result
            let tail = String(decoding: output.suffix(3000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeRuntimeError(message: reason + (tail.isEmpty ? "" : " Output: " + tail))
        }
        do {
            try NativeRuntimeFiles.require(maximumOutput > 0 && timeout > 0 && timeout.isFinite, "Invalid preparation limits.")
            var descriptors: [Int32] = [0, 0]
            try NativeRuntimeFiles.require(pipe(&descriptors) == 0, "Cannot create preparation output pipe.")
            defer { close(descriptors[0]) }
            var writeOpen = true
            defer { if writeOpen { close(descriptors[1]) } }
            try NativeRuntimeFiles.require(fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0 &&
                fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0 && fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0,
                "Cannot configure preparation output pipe.")
            var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            try NativeRuntimeFiles.require(posix_spawn_file_actions_init(&actions) == 0, "Cannot prepare tool descriptors.")
            defer { posix_spawn_file_actions_destroy(&actions) }
            try NativeRuntimeFiles.require(posix_spawnattr_init(&attributes) == 0, "Cannot prepare tool process attributes.")
            defer { posix_spawnattr_destroy(&attributes) }
            // Dispatch workers may block SIGCHLD. Inheriting that mask leaves
            // .NET helpers waiting forever for an already-exited plutil child.
            // Change only the spawned helper, never the launcher's thread mask.
            var childMask = sigset_t()
            sigemptyset(&childMask)
            try NativeRuntimeFiles.require(posix_spawnattr_setsigmask(&attributes, &childMask) == 0 &&
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK)) == 0 && posix_spawnattr_setpgroup(&attributes, 0) == 0 &&
                posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0 && posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0 &&
                posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0 && posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 &&
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0, "Cannot isolate preparation tool.")
            if let directory { try NativeRuntimeFiles.require(posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0, "Cannot select preparation directory.") }
            let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
            let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            let result = argv.withUnsafeBufferPointer { av in envp.withUnsafeBufferPointer { ev in
                posix_spawn(&pid, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: av.baseAddress!), UnsafeMutablePointer(mutating: ev.baseAddress!))
            } }
            try NativeRuntimeFiles.require(result == 0 && pid > 0, "Cannot launch \(tool): \(String(cString: strerror(result)))")
            close(descriptors[1]); writeOpen = false
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var buffer = [UInt8](repeating: 0, count: 16384), reaped = false, ended = false
            defer {
                if outcome != "success" { _ = kill(-pid, SIGKILL) }
                if !reaped {
                    _ = kill(-pid, SIGKILL)
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                }
            }
            func deadlineCheck() throws {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    _ = kill(-pid, SIGKILL)
                    try fail("\(tool) exceeded its preparation time limit during \(operation).", outcome: "timeout")
                }
            }
            while !ended || !reaped {
                try deadlineCheck()
                var descriptor = pollfd(fd: ended ? -1 : descriptors[0], events: Int16(POLLIN | POLLHUP), revents: 0)
                let polled = systemCalls.poll(&descriptor, 1, 25)
                if polled < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    try fail("\(tool) output polling failed: \(String(cString: strerror(code))).", outcome: "poll_error")
                }
                if descriptor.revents & Int16(POLLNVAL) != 0 { try fail("\(tool) output pipe became invalid.", outcome: "poll_error") }
                while !ended {
                    try deadlineCheck()
                    let count = systemCalls.read(descriptors[0], &buffer, buffer.count)
                    if count == 0 { ended = true; break }
                    if count < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        if code == EAGAIN || code == EWOULDBLOCK { break }
                        try fail("\(tool) output read failed: \(String(cString: strerror(code))).", outcome: "read_error")
                    }
                    if count > maximumOutput - output.count {
                        output.append(contentsOf: buffer.prefix(maximumOutput - output.count))
                        _ = kill(-pid, SIGKILL)
                        try fail("\(tool) exceeded its output limit.", outcome: "output_limit")
                    }
                    output.append(contentsOf: buffer.prefix(count))
                }
                if descriptor.revents & Int16(POLLERR) != 0 { try fail("\(tool) output pipe reported an error.", outcome: "poll_error") }
                if !reaped {
                    let waited = systemCalls.wait(pid, &status, WNOHANG)
                    if waited == pid { reaped = true; observedStatus = status }
                    else if waited < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        waitError = code
                        try fail("\(tool) child exit status is unavailable (waitpid: \(String(cString: strerror(code)))).", outcome: "wait_error")
                    }
                }
            }
            if status != 0 { try fail("\(tool) failed with wait status \(status).", outcome: "failed") }
            outcome = "success"
            return output
        } catch { failure = error.localizedDescription; throw error }
    }
}
