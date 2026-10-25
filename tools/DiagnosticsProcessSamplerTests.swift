import Foundation
import Darwin

@main
struct DiagnosticsProcessSamplerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scratch = root.appendingPathComponent("sampling-temporary", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let game = root.appendingPathComponent("fixture-game", isDirectory: true)
        let executable = game.appendingPathComponent("Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: executable)
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { failures.append(name) }
        }
        let identity = DiagnosticsProcessSampler.Identity(pid: getpid(), uid: geteuid(), realUID: getuid(),
            startSeconds: 123, startMicroseconds: 456, executablePath: executable.resolvingSymlinksInPath().path)
        func modified(_ original: DiagnosticsProcessSampler.Identity, pid: pid_t? = nil, uid: uid_t? = nil,
                      start: UInt64? = nil, path: String? = nil) -> DiagnosticsProcessSampler.Identity {
            .init(pid: pid ?? original.pid, uid: uid ?? original.uid, realUID: original.realUID,
                  startSeconds: start ?? original.startSeconds, startMicroseconds: original.startMicroseconds,
                  executablePath: path ?? original.executablePath)
        }
        func helper(_ name: String, _ body: String) throws -> URL {
            let path = root.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
            chmod(path.path, 0o700)
            return path
        }
        let success = try helper("sample-success", """
        [ "$1" = "\(identity.pid)" ] && [ "$2" = 1 ] && [ "$3" = 5 ] && [ "$4" = -file ] || exit 3
        [ "$(/usr/bin/stat -f %Lp "$(/usr/bin/dirname "$5")")" = 700 ] || exit 4
        [ "$(/usr/bin/stat -f %Lp "$5")" = 600 ] || exit 5
        printf 'Call graph:\\n  Thread_0 fixture\\n' > "$5"
        """)
        var base = DiagnosticsProcessSampler.Environment()
        base.processes = { [identity] }
        base.identity = { _ in identity }
        base.helper = success
        base.temporaryRoot = scratch
        func capture(_ environment: DiagnosticsProcessSampler.Environment, bytes: Int = 1024,
                     deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 10) -> DiagnosticsProcessSample {
            DiagnosticsProcessSampler.capture(gameRoot: game, deadline: deadline, maximumBytes: bytes,
                                              durationSeconds: 1, environment: environment)
        }
        func clean(_ name: String) {
            check((try? fm.contentsOfDirectory(atPath: scratch.path).isEmpty) == true, name + " cleans temporary files")
        }
        var env = base
        env.processes = { [] }
        check(capture(env).metadata["status"] as? String == "not_running", "no matching process")
        env.processes = { [modified(identity, path: identity.executablePath + "-other")] }
        check(capture(env).metadata["status"] as? String == "not_running", "reject name prefix/path near match")
        env.processes = { [modified(identity, path: "/another/game/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077")] }
        check(capture(env).metadata["status"] as? String == "not_running", "reject another installation")
        env.processes = { [modified(identity, uid: geteuid() + 1)] }
        check(capture(env).metadata["status"] as? String == "not_running", "reject another user")
        env.processes = { [identity, modified(identity, pid: identity.pid + 1)] }
        check(capture(env).metadata["status"] as? String == "ambiguous", "reject ambiguous exact matches")
        env.processes = { throw NSError(domain: "fixture", code: 1) }
        check(capture(env).metadata["status"] as? String == "unavailable", "process table failure")
        env = base
        env.identity = { _ in nil }
        check(capture(env).metadata["status"] as? String == "process_exited", "target exits before sampling")
        env.identity = { _ in modified(identity, start: 124) }
        check(capture(env).metadata["status"] as? String == "identity_changed", "reject reused PID before sampling")
        env = base
        env.helper = root.appendingPathComponent("does-not-exist")
        check(capture(env).metadata["status"] as? String == "unavailable", "missing helper")
        check(capture(base, deadline: ProcessInfo.processInfo.systemUptime).metadata["status"] as? String == "budget_exhausted", "expired deadline")
        check(capture(base, bytes: 0).metadata["status"] as? String == "budget_exhausted", "zero byte budget")
        clean("preflight")

        let captured = capture(base)
        check(captured.metadata["status"] as? String == "captured", "correct invocation and private modes")
        check(captured.text?.contains("Thread_0 fixture") == true, "capture helper output file")
        check(captured.metadata["identity_checked_before"] as? Bool == true && captured.metadata["identity_checked_after"] as? Bool == true, "identity checked twice")
        check(captured.metadata["process_start_seconds"] as? UInt64 == 123 && captured.metadata["process_start_microseconds"] as? UInt64 == 456, "retain exact process start identity")
        check(captured.metadata["capture_started_utc"] != nil && captured.metadata["capture_finished_utc"] != nil, "UTC capture times")
        clean("success")

        env = base
        env.helper = try helper("sample-denied", "echo 'task_for_pid: Operation not permitted' >&2; exit 1")
        let denied = capture(env)
        check(denied.metadata["status"] as? String == "permission_denied" && denied.text == nil, "permission denial preserved without elevation")
        env.helper = try helper("sample-failed", "echo 'sample fixture failure' >&2; exit 9")
        let failed = capture(env)
        check(failed.metadata["status"] as? String == "unavailable" && failed.text == nil, "nonzero exit without sample")
        check(failed.metadata["helper_exit_status"] as? Int32 == 9, "retain helper exit code")
        env.helper = try helper("sample-empty", "exit 0")
        check(capture(env).metadata["status"] as? String == "unavailable", "empty successful helper is not a sample")
        clean("errors")

        env.helper = try helper("sample-large", "/usr/bin/head -c 32768 /dev/zero > \"$5\"")
        let large = capture(env)
        check(large.metadata["status"] as? String == "output_limit", "oversized output has explicit status")
        check((large.text?.utf8.count ?? 0) <= 1024 && large.metadata["sample_truncated"] as? Bool == true, "sample byte limit")
        env.helper = try helper("sample-invalid-utf8", "/usr/bin/printf '\\377\\377\\377\\377\\377' > \"$5\"")
        let invalid = capture(env, bytes: 4)
        check((invalid.text?.utf8.count ?? 0) <= 4, "invalid UTF8 does not expand byte budget")
        env.helper = try helper("sample-noisy", "/usr/bin/head -c 131072 /dev/zero >&2; exec /bin/sleep 8")
        let noisyStart = ProcessInfo.processInfo.systemUptime
        let noisy = capture(env)
        check(noisy.metadata["status"] as? String == "output_limit", "noisy pipe stopped without blocking")
        check(ProcessInfo.processInfo.systemUptime - noisyStart < 2, "pipe draining has bounded time")
        check((noisy.metadata["helper_stderr"] as? String)?.utf8.count ?? 0 <= 4096, "stderr retained byte limit")
        clean("output limits")

        env = base
        let helperPIDFile = root.appendingPathComponent("timed-out-helper-pid")
        env.helper = try helper("sample-hung", "echo $$ > '\(helperPIDFile.path)'; exec /bin/sleep 8")
        env.maximumSeconds = 1.3
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        let timedOut = capture(env)
        check(timedOut.metadata["status"] as? String == "timed_out", "finite helper timeout")
        check(ProcessInfo.processInfo.systemUptime - timeoutStart < 2, "timeout returns promptly")
        let helperPID = Int32((try String(contentsOf: helperPIDFile)).trimmingCharacters(in: .whitespacesAndNewlines))!
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while kill(helperPID, 0) == 0 && ProcessInfo.processInfo.systemUptime < reapDeadline { Thread.sleep(forTimeInterval: 0.01) }
        check(kill(helperPID, 0) != 0, "only owned timed-out helper terminated")
        check(kill(getpid(), 0) == 0, "target process remains alive")
        clean("timeout")

        env = base
        var identityReads = 0
        env.identity = { _ in identityReads += 1; return identityReads == 1 ? identity : modified(identity, start: 124) }
        let reused = capture(env)
        check(reused.metadata["status"] as? String == "identity_changed" && reused.text == nil, "discard output after PID reuse")
        identityReads = 0
        env.identity = { _ in identityReads += 1; return identityReads == 1 ? identity : nil }
        let exited = capture(env)
        check(exited.metadata["status"] as? String == "process_exited" && exited.text == nil, "discard output after target exit")
        clean("identity changes")

        // Real native child, exact fixture installation path. Never discover or
        // attach to the user's actual Cyberpunk process in this test.
        let fixture = Process()
        fixture.executableURL = executable
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate() } }
        var actual = DiagnosticsProcessSampler.Environment()
        actual.temporaryRoot = scratch
        let live = capture(actual, bytes: 1024 * 1024)
        let liveStatus = live.metadata["status"] as? String ?? "missing"
        check(liveStatus == "captured", "real same-user fixture sample")
        check(live.metadata["pid"] as? pid_t == fixture.processIdentifier, "real exact process selected")
        check(live.text?.contains("Call graph:") == true, "real sample contains thread call graph")
        check(fixture.isRunning, "real sampled fixture remains running")
        clean("real sample")
        let alias = root.appendingPathComponent("fixture-symlink")
        try fm.createSymbolicLink(at: alias, withDestinationURL: game)
        let aliased = DiagnosticsProcessSampler.capture(gameRoot: alias, deadline: ProcessInfo.processInfo.systemUptime + 10,
            maximumBytes: 1024 * 1024, durationSeconds: 1, environment: actual)
        check(aliased.metadata["status"] as? String == "captured" && aliased.metadata["pid"] as? pid_t == fixture.processIdentifier, "canonical symlink root selects same fixture")
        clean("canonical sample")
        let report: [String: Any] = ["checks": checks, "failures": failures, "live_status": liveStatus,
            "live_sample_bytes": live.text?.utf8.count ?? 0]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
