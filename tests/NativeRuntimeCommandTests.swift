import Foundation
import Darwin

@main enum NativeRuntimeCommandTests {
    static var checks = 0
    static let environment = ["PATH": "/usr/bin:/bin"]
    static func check(_ value: @autoclosure () -> Bool, _ message: String = "check failed") {
        checks += 1
        if !value() { fatalError(message) }
    }
    static func refusal(_ fragment: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected failure: " + fragment) }
        catch { check(error.localizedDescription.contains(fragment), error.localizedDescription) }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("nightcity-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = URL(fileURLWithPath: "/bin/sh")
        let success = try NativeRuntimeCommand.run(shell, arguments: ["-c", "printf success"], environment: environment)
        check(String(decoding: success, as: UTF8.self) == "success")
        refusal("expected_failure") { _ = try NativeRuntimeCommand.run(shell, arguments: ["-c", "echo expected_failure; exit 3"], environment: environment) }
        let start = Date()
        refusal("before-timeout") { _ = try NativeRuntimeCommand.run(shell, arguments: ["-c", "echo before-timeout; sleep 30 & exit 0"], environment: environment, timeout: 0.1) }
        check(Date().timeIntervalSince(start) < 2)
        var calls = NativeRuntimeCommand.SystemCalls()
        calls.wait = { _, _, _ in errno = ECHILD; return -1 }
        let missingStart = Date()
        refusal("No child processes") { _ = try NativeRuntimeCommand.run(shell, arguments: ["-c", "printf child-output"], environment: environment, timeout: 3, systemCalls: calls) }
        check(Date().timeIntervalSince(missingStart) < 1, "ECHILD was converted into a timeout")
        calls = NativeRuntimeCommand.SystemCalls(); calls.poll = { _, _, _ in errno = EBADF; return -1 }
        refusal("polling failed") { _ = try NativeRuntimeCommand.run(shell, arguments: ["-c", "sleep 30"], environment: environment, systemCalls: calls) }
        calls = NativeRuntimeCommand.SystemCalls(); calls.read = { _, _, _ in errno = EIO; return -1 }
        refusal("read failed") { _ = try NativeRuntimeCommand.run(shell, arguments: ["-c", "sleep 30"], environment: environment, systemCalls: calls) }
        // A continuously readable producer must not bypass the inner deadline.
        calls = NativeRuntimeCommand.SystemCalls(); calls.read = { _, buffer, _ in usleep(10000); buffer!.storeBytes(of: UInt8(120), as: UInt8.self); return 1 }
        let drainingStart = Date()
        refusal("time limit") { _ = try NativeRuntimeCommand.run(shell, arguments: ["-c", "sleep 30"], environment: environment, maximumOutput: 1024 * 1024, timeout: 0.06, systemCalls: calls) }
        check(Date().timeIntervalSince(drainingStart) < 1)
        refusal("output limit") { _ = try NativeRuntimeCommand.run(URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], environment: environment, maximumOutput: 100, timeout: 2) }
        // A helper with a recognized basename records metadata, never argv/env.
        let tool = root.appendingPathComponent("nctool")
        try Data("#!/bin/sh\nprintf log-output\nexit 0\n".utf8).write(to: tool); check(chmod(tool.path, 0o700) == 0)
        for _ in 0..<18 { _ = try NativeRuntimeCommand.run(tool, arguments: ["compat25", "argv-secret"], directory: root, environment: environment.merging(["TEST_SECRET": "env-secret"], uniquingKeysWith: { _, v in v })) }
        let logs = root.appendingPathComponent(NativeRuntimeManifest.dataPath + "/logs")
        let entries = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        check(entries.count == 16)
        let text = try String(contentsOf: entries[0], encoding: .utf8)
        check(text.contains("log-output") && text.contains("compat25") && !text.contains("argv-secret") && !text.contains("env-secret"))
        let record = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        check(record["outcome"] as? String == "success" && record["wait_status"] as? Int == 0)
        // Match Add Mod's background caller. Only the child mask changes;
        // the worker keeps its original deliberately blocked SIGCHLD.
        check(CommandLine.arguments.count == 2)
        let info = root.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.5.0"], format: .xml, options: 0).write(to: info)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var blocked = sigset_t(), prior = sigset_t()
            sigemptyset(&blocked); sigaddset(&blocked, SIGCHLD)
            check(pthread_sigmask(SIG_BLOCK, &blocked, &prior) == 0)
            defer { pthread_sigmask(SIG_SETMASK, &prior, nil); completed.signal() }
            do {
                let result = try NativeRuntimeCommand.run(URL(fileURLWithPath: CommandLine.arguments[1]), arguments: [info.path], environment: environment, timeout: 3)
                check(String(decoding: result, as: UTF8.self).contains("SIGCHLD=unblocked child=done"))
                var after = sigset_t(); check(pthread_sigmask(SIG_SETMASK, nil, &after) == 0 && sigismember(&after, SIGCHLD) == 1)
            } catch { fatalError("Blocked-worker child failed: " + error.localizedDescription) }
        }
        let completedInTime = completed.wait(timeout: .now() + 5)
        check(completedInTime == .success)
        // Match the actual ECHILD case too, without assuming it caused this player failure.
        let previous = signal(SIGCHLD, SIG_IGN)
        let actualStart = Date()
        refusal("child exit status is unavailable") { _ = try NativeRuntimeCommand.run(shell, arguments: ["-c", "printf actual-child"], environment: environment, timeout: 2) }
        _ = signal(SIGCHLD, previous)
        check(Date().timeIntervalSince(actualStart) < 1)
        print("Native preparation command regression checks passed: \(checks). Real SIGCHLD-ignore reproduces ECHILD and now fails immediately; no game launched.")
    }
}
