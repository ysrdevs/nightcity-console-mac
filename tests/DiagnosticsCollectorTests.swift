import Foundation
import Darwin

@main
struct DiagnosticsCollectorTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("nightcity-diagnostics-tests-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let game = fixture.appendingPathComponent("Game"), home = fixture.appendingPathComponent("Home"), temp = fixture.appendingPathComponent("Tmp")
        for url in [game, home, temp] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        func write(_ root: URL, _ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        var snapshot = DiagnosticsSnapshot(gameRoot: game, appBundle: fixture.appendingPathComponent("NightCity.app"), appVersion: "1.7.0.0",
            gameVersion: "2.5.0", installed: true, status: "Ready\npassword=STATUS_PRIVATE", operationInProgress: false, native25: true, separateScriptCache: true)
        snapshot.home = home; snapshot.temporaryRoot = temp; snapshot.includeSystemInformation = false
        // Never inspect the real process table or sample a game from this fixture.
        func collect(_ limits: DiagnosticsLimits = DiagnosticsLimits(),
                     sample: DiagnosticsProcessSample = DiagnosticsProcessSample(metadata: ["status": "not_running"], text: nil)) -> DiagnosticsReport {
            DiagnosticsCollector(snapshot: snapshot, limits: limits, sampleProvider: { _, _, _ in sample }).collect()
        }
        func object(_ report: DiagnosticsReport, _ name: String) throws -> [String: Any] {
            let data = report.entries.first { $0.name == name }!.data
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func array(_ report: DiagnosticsReport, _ name: String) throws -> [[String: Any]] {
            try JSONSerialization.jsonObject(with: report.entries.first { $0.name == name }!.data) as! [[String: Any]]
        }
        func writeJSON(_ root: URL, _ path: String, _ value: Any) throws {
            try write(root, path, String(decoding: JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        }
        precondition(DiagnosticsDirectory(URL(fileURLWithPath: "/private/tmp", isDirectory: true)) != nil,
                     "macOS /private/tmp must not be rewritten to a symlink rejected by O_NOFOLLOW")
        let redactor = DiagnosticsRedactor(snapshot: snapshot)
        let privateText = """
        Game at \(game.path)/r6/scripts/Example.reds
        Personal \(home.path)/Documents/Private Project/report.txt
        Other /Users/alice/Documents/private.txt
        External /Volumes/My Private Disk/Documents/private.txt
        Escaped \\/Users\\/alice\\/Documents\\/private.txt
        Steam 76561198012345678 userdata/123456789
        Email person@example.com address 192.168.1.2
        password=PRIVATE_PASSWORD
        Authorization: Bearer PRIVATE_TOKEN
        https://example.invalid/?token=PRIVATE_QUERY_TOKEN
        submitted: print('PRIVATE_COMMAND')
        queued: Game.PrivateCommand()
        > PRIVATE_COMMAND_TWO
        """
        let redacted = redactor.text(privateText)
        for secret in [home.path, "alice", "Private Project", "My Private Disk", "76561198012345678", "123456789", "person@example.com", "192.168.1.2", "PRIVATE_PASSWORD", "PRIVATE_TOKEN", "PRIVATE_QUERY_TOKEN", "PRIVATE_COMMAND", "Game.PrivateCommand"] {
            precondition(!redacted.contains(secret), "Redaction leaked \(secret)")
        }
        precondition(redacted.contains("<GAME>/r6/scripts/Example.reds"), "Keep useful game-relative paths")
        print("PASS personal paths, Steam IDs, contact data, credentials and console commands are redacted")

        try write(game, "red4ext/logs/red4ext-current.log", "LOADER_OK\n" + privateText)
        try write(game, "red4ext/logs/red4ext-old.log", "OLD_LOG_SECRET")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86400)], ofItemAtPath: game.appendingPathComponent("red4ext/logs/red4ext-old.log").path)
        try write(game, "red4ext/logs/unrelated.log", "UNRELATED_LOG_SECRET")
        try write(game, "red4ext/RED4ext.dylib", "abc")
        try write(game, "red4ext/logs/hookstats.json", "{\"schema\":1,\"hooks\":[{\"name\":\"test_hook\",\"hits\":27}],\"password=KEY_PRIVATE\":\"metadata\",\"token\":\"JSON_PRIVATE_TOKEN\",\"commandLine\":[\"JSON_PRIVATE_COMMAND\"]}")
        try write(game, "red4ext/logs/milestones.log", "CHECK bootstrap pass")
        try write(game, "r6/scripts/Example/main.reds", "SOURCE_MUST_NOT_BE_READ")
        try write(game, "archive/Mac/mod/Example.archive", "ARCHIVE_MUST_NOT_BE_READ")
        try write(game, "r6/scripts/saves/Private.reds", "SAVE_MUST_NOT_BE_READ")
        try write(game, "saves/ManualSave-0/sav.dat", "SAVE_MUST_NOT_BE_READ")
        try write(game, "r6/scripts/personal.txt", "DOCUMENT_MUST_NOT_BE_READ")
        try write(game, "r6/scripts/Example/password=FILENAME_PRIVATE.reds", "SOURCE_MUST_NOT_BE_READ")
        try write(temp, "cp2077_overlay.log", "frametime: avg=16ms\nsubmitted: print('COMMAND_PRIVATE')\n")
        try write(temp, "cp2077_out.txt", """
        [Flight] Normal collision restored; queued arrival remains unconfirmed; Start can request a read-only recheck; active=false; arrivalPending=false; arrivalUnconfirmed=true; restoreUnconfirmed=false; recoveryUsed=true
        ==== MINI-CET v3 (universal call + perks/attrs/relic) ready ====
        queued: print('COMMAND_PRIVATE')
        USER_PRINT_PRIVATE
        Creator: FAILED: private weapon name
        Creator: FAILED: Creator cannot find the local player. Load a save first.
        [Flight] Queued relocation arrival observed with normal collision; press Start again for a new flight; active=false; arrivalPending=false; arrivalUnconfirmed=false; restoreUnconfirmed=false; recoveryUsed=false; arrivalSerial=3; arrivalCallbacks=2/64; arrivalElapsed=0.0234/0.5; arrivalDistance=0
        [Flight] TOKEN=FLIGHT_SECRET_PRIVATE; active=true; arrivalPending=true; arrivalUnconfirmed=true; restoreUnconfirmed=true; recoveryUsed=true
        """)
        try write(temp, "cp2077_perf.json", "{\"schema_version\":1,\"frame_count\":120,\"avg_ms\":16.7}")
        try write(temp, "cp2077_cmd.txt", "COMMAND_INPUT_PRIVATE")
        try write(home, "Library/Logs/DiagnosticReports/Cyberpunk2077-test.ips", "GAME_CRASH\n" + privateText)
        try write(home, "Library/Logs/DiagnosticReports/Mail-test.ips", "OTHER_APP_CRASH_PRIVATE")
        try write(home, "Library/Application Support/CD Projekt Red/Cyberpunk 2077/UserSettings.json", """
        {"data":[{"group_name":"/graphics/basic","options":[{"name":"Quality","value":"High","default_value":"IGNORED_DEFAULT"}]},
        {"group_name":"/video/display","options":[{"name":"Resolution","value":"1920x1080"}]},
        {"group_name":"/gallery/favorites","options":[{"name":"PrivatePicture","value":"GALLERY_PRIVATE"}]}]}
        """)
        let outside = fixture.appendingPathComponent("outside-secret.txt")
        try Data("SYMLINK_ESCAPE_PRIVATE".utf8).write(to: outside)
        try fm.createSymbolicLink(atPath: game.appendingPathComponent("red4ext/logs/red4ext-link.log").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: game.appendingPathComponent("r6/scripts/Escape").path, withDestinationPath: fixture.path)
        let scope = DiagnosticsDirectory(game)!
        precondition(scope.read("red4ext/logs/red4ext-link.log", maximum: 100) == nil)
        precondition(scope.read("r6/scripts/Escape/outside-secret.txt", maximum: 100) == nil)
        precondition(scope.read("../outside-secret.txt", maximum: 100) == nil)
        precondition(scope.read(outside.path, maximum: 100) == nil)
        let fifo = game.appendingPathComponent("red4ext/logs/red4ext-pipe.log").path
        precondition(mkfifo(fifo, 0o600) == 0)
        precondition(scope.read("red4ext/logs/red4ext-pipe.log", maximum: 100) == nil)
        print("PASS descendant symlinks, path traversal and FIFOs are rejected without reading outside the scope")

        let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try write(game, "archive/pc/mod/WindowsLayout.archive", "PC_ARCHIVE_CONTENT_PRIVATE")
        try write(game, "red4ext/red4ext_hooks.js", "RUNTIME_JS_SOURCE_PRIVATE")
        try write(snapshot.appBundle, "Contents/Resources/red4ext_hooks.js", "RUNTIME_JS_SOURCE_PRIVATE")
        try write(game, "red4ext/sources.lock.json", "PRIVATE_SOURCE_LOCK_MUST_NOT_EXPORT")
        try writeJSON(game, "red4ext/BUILD_INFO.json", ["schema": 3, "game_version": "2.5.0", "profile": "ui-with-verified-wardrobe",
            "repository": "PRIVATE_REPOSITORY_PROVENANCE", "files": ["private-implementation.cpp": abcHash, "plugins/Codeware/Scripts/Good.reds": abcHash]])
        try write(game, "red4ext/config.ini", """
        version = 0
        [dev]
        strict_version_check = true # CONFIG_COMMENT_PRIVATE
        secret = "CONFIG_UNKNOWN_PRIVATE"
        [plugins]
        enabled = true
        ignored = ["CONFIG_MOD_NAME_PRIVATE"]
        [logging]
        level = "debug"
        max_files = 5
        [hooking]
        core_hooks = ["CGameApplication_AddState", "CONFIG_HOOK_NAME_PRIVATE"]
        [private]
        value = "CONFIG_SECTION_PRIVATE"
        """)
        try writeJSON(game, "red4ext/FridaGadget.config", ["interaction": ["type": "script", "path": "./red4ext_hooks.js", "on_load": "wait", "unknown": "FRIDA_PRIVATE"]])
        try writeJSON(snapshot.appBundle, "Contents/Resources/FridaGadget.config", ["interaction": ["type": "script", "path": "./red4ext_hooks.js", "on_load": "resume"]])
        let scriptPrefix = "r6/scripts/zz_nightcity_plugins/Codeware/"
        try write(game, scriptPrefix + "Good.reds", "abc")
        try write(game, scriptPrefix + "Changed.reds", "def")
        try fm.createDirectory(at: game.appendingPathComponent(scriptPrefix + "Directory.reds"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: game.appendingPathComponent(scriptPrefix + "Link.reds").path, withDestinationPath: outside.path)
        precondition(mkfifo(game.appendingPathComponent(scriptPrefix + "Pipe.reds").path, 0o600) == 0)
        let scriptManifest = ["Codeware/Good.reds": abcHash, "Codeware/Changed.reds": abcHash,
            "Codeware/Missing.reds": abcHash, "Codeware/Directory.reds": abcHash, "Codeware/Link.reds": abcHash, "Codeware/Pipe.reds": abcHash,
            "../outside-secret.txt": abcHash, "Codeware/Bad.reds": "invalid-hash"]
        try writeJSON(game, "red4ext/nightcity-plugin-scripts.json", scriptManifest)
        let explorationNames = ["NCCCollisionFlightProbe.reds", "NCCFlightClearance.reds"]
        let explorationManifest: [String: Any] = ["schema": 1, "game_version": "2.5.0",
            "files": Dictionary(uniqueKeysWithValues: explorationNames.map { ($0, abcHash) })]
        try writeJSON(snapshot.appBundle, "Contents/Resources/exploration/manifest.json", explorationManifest)
        try writeJSON(game, "red4ext/nightcity-exploration.json", explorationManifest)
        for name in explorationNames { try write(snapshot.appBundle, "Contents/Resources/exploration/" + name, "abc") }
        try write(game, "r6/scripts/NightCityExploration/" + explorationNames[0], "abc")
        try write(game, "r6/scripts/NightCityExploration/" + explorationNames[1], "EXPLORATION_SOURCE_PRIVATE")

        let report = collect()
        let all = report.entries.map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n")
        for secret in ["OLD_LOG_SECRET", "UNRELATED_LOG_SECRET", "SOURCE_MUST_NOT_BE_READ", "ARCHIVE_MUST_NOT_BE_READ", "SAVE_MUST_NOT_BE_READ", "DOCUMENT_MUST_NOT_BE_READ", "OTHER_APP_CRASH_PRIVATE", "SYMLINK_ESCAPE_PRIVATE", "COMMAND_PRIVATE", "USER_PRINT_PRIVATE", "COMMAND_INPUT_PRIVATE", "GALLERY_PRIVATE", "IGNORED_DEFAULT", "STATUS_PRIVATE", "FILENAME_PRIVATE", "KEY_PRIVATE", "JSON_PRIVATE_TOKEN", "JSON_PRIVATE_COMMAND"] {
            precondition(!all.contains(secret), "Collector included \(secret)")
        }
        precondition(all.contains("LOADER_OK") && all.contains("GAME_CRASH") && all.contains("frame_count"))
        precondition(all.contains("test_hook") && all.contains("CHECK bootstrap pass") && all.contains("player_unavailable"))
        let summary = try JSONSerialization.jsonObject(with: report.entries.first { $0.name == "summary.json" }!.data) as! [String: Any]
        precondition(summary["launcher_version"] as? String == "1.7.0.0", "Four-component version fields are not IP addresses")
        precondition(all.contains("Example/main.reds") && all.contains("Example.archive"), "Inventory lists names without reading content")
        precondition(all.contains("archive/pc/mod/WindowsLayout.archive"), "Windows-style archive placement must remain visible in inventory")
        for secret in ["PC_ARCHIVE_CONTENT_PRIVATE", "RUNTIME_JS_SOURCE_PRIVATE", "PRIVATE_SOURCE_LOCK_MUST_NOT_EXPORT", "PRIVATE_REPOSITORY_PROVENANCE",
                       "private-implementation.cpp", "CONFIG_COMMENT_PRIVATE", "CONFIG_UNKNOWN_PRIVATE", "CONFIG_MOD_NAME_PRIVATE", "CONFIG_HOOK_NAME_PRIVATE", "CONFIG_SECTION_PRIVATE", "FRIDA_PRIVATE"] {
            precondition(!all.contains(secret), "New diagnostic collection leaked \(secret)")
        }
        precondition(!report.entries.contains { $0.name.contains("sources.lock") })
        let flightSummary = try object(report, "logs/flight-summary.json")
        let flightEntries = flightSummary["entries"] as! [[String: Any]]
        precondition(flightEntries.count == 1 && flightEntries[0]["category"] as? String == "arrival_confirmed")
        precondition(flightEntries[0]["arrivalUnconfirmed"] as? Bool == false && flightEntries[0]["arrivalSerial"] as? Int == 3)
        precondition(flightSummary["source_file"] != nil && flightSummary["session_note"] is String)
        precondition(flightSummary["boundary_found"] as? Bool == true && flightSummary["source_tail_truncated"] as? Bool == false)
        precondition(!all.contains("FLIGHT_SECRET_PRIVATE") && !all.contains("[Flight]"))
        precondition(!all.contains("EXPLORATION_SOURCE_PRIVATE"))
        let exploration = try object(report, "exploration-integrity.json")
        let explorationFiles = exploration["files"] as! [[String: Any]]
        precondition(exploration["bundled_manifest_valid"] as? Bool == true && exploration["installed_manifest_valid"] as? Bool == true)
        precondition(explorationFiles.first { ($0["path"] as? String)?.hasSuffix(explorationNames[0]) == true }?["matches_bundled"] as? Bool == true)
        precondition(explorationFiles.first { ($0["path"] as? String)?.hasSuffix(explorationNames[1]) == true }?["matches_install_manifest"] as? Bool == false)
        let runtime = try array(report, "runtime-files.json")
        precondition(runtime.first { ($0["path"] as? String)?.hasSuffix("red4ext_hooks.js") == true }?["matches_bundled"] as? Bool == true)
        precondition(runtime.first { ($0["path"] as? String)?.hasSuffix("FridaGadget.config") == true }?["matches_bundled"] as? Bool == false)
        let config = try object(report, "runtime-config.json")
        let loaderConfig = config["loader"] as! [String: Any], fridaConfig = config["frida"] as! [String: Any]
        precondition(loaderConfig["dev.strict_version_check"] as? Bool == true && loaderConfig["plugins.enabled"] as? Bool == true)
        precondition(loaderConfig["logging.level"] as? String == "debug" && loaderConfig["logging.max_files"] as? Int == 5)
        precondition(loaderConfig["plugins.ignored_count"] as? Int == 1 && loaderConfig["hooking.core_hooks_count"] as? Int == 2)
        precondition(loaderConfig["hooking.includes_application_state"] as? Bool == true)
        precondition(fridaConfig["type"] as? String == "script" && fridaConfig["on_load"] as? String == "wait" && fridaConfig["expected_script_path"] as? Bool == true)
        let integrity = try object(report, "script-integrity.json")
        let integrityFiles = integrity["files"] as! [[String: Any]]
        precondition(integrity["manifest_entries"] as? Int == scriptManifest.count && integrity["rejected_entries"] as? Int == 2)
        for (file, status) in [("Good.reds", "matches"), ("Changed.reds", "mismatch"), ("Missing.reds", "missing_or_not_regular"),
                               ("Directory.reds", "missing_or_not_regular"), ("Link.reds", "missing_or_not_regular"), ("Pipe.reds", "missing_or_not_regular")] {
            precondition(integrityFiles.first { $0["path"] as? String == scriptPrefix + file }?["status"] as? String == status, "Wrong integrity result for \(file)")
        }
        precondition(all.contains("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "SHA-256 of abc matches known digest")
        let graphics = report.entries.first { $0.name == "graphics-settings.json" }!
        precondition(String(decoding: graphics.data, as: UTF8.self).contains("1920x1080"))
        for entry in report.entries where entry.name.hasSuffix(".json") {
            precondition((try? JSONSerialization.jsonObject(with: entry.data)) != nil, "Structured metadata must remain valid JSON")
        }
        print("PASS recent scoped logs, native hash, metadata-only mod inventory and selected graphics settings; excluded saves, sources, unrelated apps and console history")
        print("PASS runtime digests, typed config allowlist, source-provenance exclusion and actual staged-script integrity")
        print("PASS packaged and installed Exploration hashes distinguish modified scripts without exporting contents")
        print("PASS typed flight summary retains current log-segment evidence without command history or raw status messages")

        try write(game, "red4ext/logs/red4ext-large.log", String(repeating: "x", count: 100_000) + "TAIL_MARKER")
        let tail = scope.read("red4ext/logs/red4ext-large.log", maximum: 128)!
        precondition(tail.count == 128 && String(decoding: tail, as: UTF8.self).hasSuffix("TAIL_MARKER"))
        precondition(scope.hash("red4ext/logs/red4ext-large.log", maximum: 100, deadline: .greatestFiniteMagnitude) == nil)
        var tiny = DiagnosticsLimits(); tiny.totalBytes = 512; tiny.files = 2; tiny.textBytes = 64; tiny.inventoryEntries = 1
        let bounded = collect(tiny)
        precondition(bounded.entries.count <= 2 && bounded.entries.reduce(0) { $0 + $1.data.count } <= 512)
        var narrow = DiagnosticsLimits(); narrow.inventoryEntries = 1
        let inventoryData = collect(narrow).entries.first { $0.name == "mod-inventory.json" }!.data
        let inventoryObject = try JSONSerialization.jsonObject(with: inventoryData) as! [String: Any]
        precondition((inventoryObject["files"] as! [[String: Any]]).count <= 1)
        var limitedJSON = DiagnosticsLimits(); limitedJSON.totalBytes = 1800
        for entry in collect(limitedJSON).entries where entry.name.hasSuffix(".json") {
            precondition((try? JSONSerialization.jsonObject(with: entry.data)) != nil, "A byte cap must omit rather than corrupt structured metadata")
        }
        var expired = DiagnosticsLimits(); expired.seconds = 0
        let fast = DiagnosticsCollector(snapshot: snapshot, limits: expired, sampleProvider: { _, _, _ in
            preconditionFailure("An exhausted deadline must not start a process sample")
        }).collect()
        precondition(!fast.entries.contains { ($0.name.hasPrefix("logs/") && $0.name != "logs/log-index.json") || $0.name == "native-binaries.json" })
        precondition(fast.sampleStatus == "time_budget_exhausted")
        print("PASS log tail, hashing, total-byte, file-count and expired time-budget limits")

        let decisiveStack = "GarmentWrapper::OnAppearanceSuffix / SharedMutex::LockShared [0x10001234]"
        let sampleText = privateText + "\n" + String(repeating: "    100 EngineWorker::Wait [0x10001000]\n", count: 6000) + decisiveStack
        var sampled = false
        let withSample = DiagnosticsCollector(snapshot: snapshot, sampleProvider: { selectedGame, deadline, maximum in
            precondition(selectedGame == game, "Sampling must receive the selected installation")
            precondition(deadline > ProcessInfo.processInfo.systemUptime && maximum == 1024 * 1024)
            sampled = true
            return DiagnosticsProcessSample(metadata: ["status": "captured", "pid": pid_t(12345),
                "process_started_utc": "2026-10-25T18:50:00Z", "token": "SAMPLE_METADATA_PRIVATE"], text: sampleText)
        }).collect()
        let sampleEntry = withSample.entries.first { $0.name == "process/game-thread-sample.txt" }!
        let exportedSample = String(decoding: sampleEntry.data, as: UTF8.self)
        precondition(sampled && withSample.sampleStatus == "captured")
        precondition(sampleEntry.data.count > DiagnosticsLimits().textBytes && exportedSample.hasSuffix(decisiveStack),
                     "Thread samples need their own budget: retain the decisive stack beyond the old 128 KiB log limit")
        precondition(withSample.entries.firstIndex { $0.name == sampleEntry.name }! < withSample.entries.firstIndex { $0.name.hasPrefix("logs/loader-") }!,
                     "Capture and store the sample before optional log/hash collection")
        let sampleMetadata = try object(withSample, "process/game-process.json")
        precondition(sampleMetadata["export_text_truncated"] as? Bool == false)
        precondition(sampleMetadata["exported_text_bytes"] as? Int == sampleEntry.data.count)
        let sampleReportText = withSample.entries.map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n")
        for secret in ["SAMPLE_METADATA_PRIVATE", "PRIVATE_PASSWORD", "PRIVATE_TOKEN", "PRIVATE_COMMAND", "person@example.com", "My Private Disk", home.path] {
            precondition(!sampleReportText.contains(secret), "Sample export leaked \(secret)")
        }
        for status in ["not_running", "permission_denied", "process_exited", "identity_changed", "timed_out", "ambiguous", "unavailable"] {
            let failedSample = collect(sample: DiagnosticsProcessSample(metadata: ["status": status], text: nil))
            let failureMetadata = try object(failedSample, "process/game-process.json")
            precondition(failedSample.sampleStatus == status)
            precondition(failureMetadata["status"] as? String == status)
            precondition(failedSample.entries.contains { $0.name.hasPrefix("logs/loader-") }, "Sampling failure must not suppress other diagnostics")
            precondition(!failedSample.entries.contains { $0.name == "process/game-thread-sample.txt" })
        }
        let oversized = collect(sample: DiagnosticsProcessSample(metadata: ["status": "captured"],
            text: String(repeating: "s", count: 1024 * 1024 + 400) + "BEYOND_SAMPLE_LIMIT"))
        let clipped = oversized.entries.first { $0.name == "process/game-thread-sample.txt" }!
        let clippedMetadata = try object(oversized, "process/game-process.json")
        precondition(clipped.data.count == 1024 * 1024)
        precondition(clippedMetadata["export_text_truncated"] as? Bool == true)
        var constrained = DiagnosticsLimits(); constrained.totalBytes = 64 * 1024
        let sampleBounded = collect(constrained, sample: DiagnosticsProcessSample(metadata: ["status": "captured"], text: sampleText))
        let boundedSampleMetadata = try object(sampleBounded, "process/game-process.json")
        precondition(sampleBounded.entries.reduce(0) { $0 + $1.data.count } <= constrained.totalBytes)
        precondition(boundedSampleMetadata["export_text_truncated"] as? Bool == true,
                     "Reserve valid status metadata even when the remaining export budget clips the sample")
        print("PASS injected sampling, complete large stacks, redaction, explicit failure states and bounded sample exports")

        // Real source dates, not export order, must distinguish an earlier crash
        // and a reused process ID from this sampled session.
        let now = Date().timeIntervalSince1970, processStart = Int(now) - 60
        let liveMetadata: [String: Any] = ["status": "captured", "pid": pid_t(12345),
            "process_start_seconds": processStart, "process_start_microseconds": 0,
            "identity_checked_before": true, "identity_checked_after": true]
        let liveSample = DiagnosticsProcessSample(metadata: liveMetadata, text: "fixture call graph")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(processStart - 60))],
                             ofItemAtPath: home.appendingPathComponent("Library/Logs/DiagnosticReports/Cyberpunk2077-test.ips").path)
        try write(game, "red4ext/logs/red4ext-head-tail.log", "STARTUP_IDENTITY_MARKER\n" + String(repeating: "m", count: 400_000) + "\nFINAL_RESULT_MARKER")
        try writeJSON(temp, "cp2077_runtime_diagnostics.json", ["schema_version": 1, "process_id": 12345,
            "script_loaded_at_unix": Double(processStart + 2), "updated_at_unix": now,
            "executor_filter": "native", "localization_filter": "native", "game_support": "supported",
            "unknown": "RUNTIME_STATUS_PRIVATE"])
        let dated = collect(sample: liveSample)
        let logIndex = try array(dated, "logs/log-index.json")
        let indexed = logIndex.first { ($0["source"] as? String)?.hasSuffix("red4ext-head-tail.log") == true }!
        let excerpt = String(decoding: dated.entries.first { $0.name == indexed["export"] as? String }!.data, as: UTF8.self)
        precondition(excerpt.contains("STARTUP_IDENTITY_MARKER") && excerpt.contains("FINAL_RESULT_MARKER") && excerpt.contains("Middle of log omitted"))
        precondition(indexed["truncated"] as? Bool == true && indexed["modified_unix"] is NSNumber && indexed["modified_utc"] is String)
        let crashIndex = try array(dated, "crashes/index.json")
        precondition(crashIndex.count == 1 && crashIndex[0]["session_relation"] as? String == "predates_sampled_process")
        var runtimeStatus = try object(dated, "logs/runtime-status.json")
        precondition(runtimeStatus["session_relation"] as? String == "matches_sampled_process")
        precondition(!dated.entries.map { String(decoding: $0.data, as: UTF8.self) }.joined().contains("RUNTIME_STATUS_PRIVATE"))
        var rejectedIdentity = liveMetadata
        rejectedIdentity["status"] = "identity_changed"; rejectedIdentity["identity_checked_after"] = false
        let unverifiedRuntime = try object(collect(sample: DiagnosticsProcessSample(metadata: rejectedIdentity, text: nil)), "logs/runtime-status.json")
        precondition(unverifiedRuntime["session_relation"] as? String != "matches_sampled_process",
                     "A failed process identity check must not certify a runtime sidecar as current")
        try writeJSON(temp, "cp2077_runtime_diagnostics.json", ["schema_version": 1, "process_id": 12345,
            "script_loaded_at_unix": Double(processStart - 600), "updated_at_unix": now])
        runtimeStatus = try object(collect(sample: liveSample), "logs/runtime-status.json")
        precondition(runtimeStatus["session_relation"] as? String == "different_or_stale_process", "PID equality cannot make an old runtime file current")
        print("PASS startup/final log excerpts, source timestamps, stale crash index and runtime process-birth matching")

        try write(game, "red4ext/nightcity-plugin-scripts.json", "{malformed")
        let malformedIntegrity = try object(collect(), "script-integrity.json")
        precondition(malformedIntegrity["status"] as? String == "manifest_missing_or_invalid")
        try writeJSON(game, "red4ext/nightcity-plugin-scripts.json", scriptManifest)
        try writeJSON(game, "red4ext/nightcity-exploration.json", ["schema": 1, "game_version": "2.5.0", "files": ["../outside-secret.txt": abcHash]])
        let invalidExploration = try object(collect(), "exploration-integrity.json")
        precondition(invalidExploration["installed_manifest_valid"] as? Bool == false)
        precondition((invalidExploration["files"] as! [[String: Any]]).count == 2)
        try writeJSON(game, "red4ext/nightcity-exploration.json", explorationManifest)
        var noHashBudget = DiagnosticsLimits(); noHashBudget.hashBytes = 2
        let limitedIntegrity = try object(collect(noHashBudget), "script-integrity.json")
        let limitedFiles = limitedIntegrity["files"] as! [[String: Any]]
        precondition(limitedFiles.first { $0["path"] as? String == scriptPrefix + "Good.reds" }?["status"] as? String == "size_or_time_budget")

        // Legacy 2.3.1 keeps its database next to the loader; the 2.5 bin/x64
        // location must not be accidentally used for the older supported path.
        try write(game, "red4ext/cyberpunk2077_addresses.json", "LEGACY_DB_CONTENT_PRIVATE")
        try write(snapshot.appBundle, "Contents/Resources/cyberpunk2077_addresses.json", "LEGACY_DB_CONTENT_PRIVATE")
        var legacy = DiagnosticsSnapshot(gameRoot: game, appBundle: snapshot.appBundle, appVersion: "1.7.1", gameVersion: "2.3.1",
            installed: true, status: "Ready", operationInProgress: false, native25: false, separateScriptCache: false)
        legacy.home = home; legacy.temporaryRoot = temp; legacy.includeSystemInformation = false
        let legacyReport = DiagnosticsCollector(snapshot: legacy, sampleProvider: { _, _, _ in DiagnosticsProcessSample(metadata: ["status": "not_running"], text: nil) }).collect()
        let legacyFiles = try array(legacyReport, "runtime-files.json")
        let legacyDB = legacyFiles.first { $0["path"] as? String == "<GAME>/red4ext/cyberpunk2077_addresses.json" }!
        precondition(legacyDB["matches_bundled"] as? Bool == true)
        precondition(!legacyReport.entries.map { String(decoding: $0.data, as: UTF8.self) }.joined().contains("LEGACY_DB_CONTENT_PRIVATE"))
        print("PASS malformed/bounded script integrity and legacy 2.3.1 database identity")

        let zip = fixture.appendingPathComponent("report.zip")
        try report.zipData().write(to: zip)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", zip.path]; try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ZIP is accepted by an independent reader with CRC verification")
        print("PASS exported ZIP structure and all entry CRCs verified by unzip")
    }
}
