import Foundation
import Darwin

// Each preparation tool has its own process group created atomically at spawn.
// Timeout/output cancellation targets only that owned group, including nctool
// children, and pipe reads have a deadline even if a descendant retains stdout.
enum NativeRuntimeCommand {
    static func run(_ executable: URL, arguments: [String], directory: URL? = nil,
                    environment: [String: String], maximumOutput: Int = 256 * 1024, timeout: TimeInterval = 120) throws -> Data {
        try NativeRuntimeFiles.require(maximumOutput > 0 && timeout > 0, "Invalid preparation limits.")
        var descriptors: [Int32] = [0, 0]
        try NativeRuntimeFiles.require(pipe(&descriptors) == 0, "Cannot create preparation output pipe.")
        defer { close(descriptors[0]) }
        var writeOpen = true
        defer { if writeOpen { close(descriptors[1]) } }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        try NativeRuntimeFiles.require(posix_spawn_file_actions_init(&actions) == 0, "Cannot prepare tool descriptors.")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try NativeRuntimeFiles.require(posix_spawnattr_init(&attributes) == 0, "Cannot prepare tool process attributes.")
        defer { posix_spawnattr_destroy(&attributes) }
        try NativeRuntimeFiles.require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0 && posix_spawnattr_setpgroup(&attributes, 0) == 0 &&
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0 && posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0 &&
            posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0 && posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 &&
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0, "Cannot isolate preparation tool.")
        if let directory { try NativeRuntimeFiles.require(posix_spawn_file_actions_addchdir(&actions, directory.path) == 0, "Cannot select preparation directory.") }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { av in envp.withUnsafeBufferPointer { ev in
            posix_spawn(&pid, executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: av.baseAddress!), UnsafeMutablePointer(mutating: ev.baseAddress!))
        } }
        try NativeRuntimeFiles.require(result == 0 && pid > 0, "Cannot launch \(executable.lastPathComponent): \(String(cString: strerror(result)))")
        close(descriptors[1]); writeOpen = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        var status: Int32 = 0, reaped = false, ended = false, overflow = false, expired = false
        defer {
            if !reaped { _ = kill(-pid, SIGKILL); while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        while !ended || !reaped {
            if ProcessInfo.processInfo.systemUptime >= deadline { expired = true; _ = kill(-pid, SIGKILL); break }
            var descriptor = pollfd(fd: ended ? -1 : descriptors[0], events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 25)
            while !ended {
                let count = read(descriptors[0], &buffer, buffer.count)
                if count == 0 { ended = true; break }
                if count < 0 { if errno == EINTR { continue }; break }
                if count > maximumOutput - output.count { overflow = true; _ = kill(-pid, SIGKILL); break }
                output.append(contentsOf: buffer.prefix(count))
            }
            if overflow { break }
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true }
            }
        }
        // Kill the full owned group before reporting a bound violation, even
        // when the original helper exited before a child closed its pipe.
        if expired || overflow { _ = kill(-pid, SIGKILL) }
        try NativeRuntimeFiles.require(!expired, "\(executable.lastPathComponent) exceeded its preparation time limit.")
        try NativeRuntimeFiles.require(!overflow, "\(executable.lastPathComponent) exceeded its output limit.")
        try NativeRuntimeFiles.require(status == 0, "\(executable.lastPathComponent) failed: \(String(decoding: output.suffix(3000), as: UTF8.self))")
        return output
    }
}
