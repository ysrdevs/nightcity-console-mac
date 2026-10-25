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
        try write(temp, "cp2077_out.txt", "queued: print('COMMAND_PRIVATE')\nUSER_PRINT_PRIVATE\nCreator: FAILED: private weapon name\nCreator: FAILED: Creator cannot find the local player. Load a save first.\n")
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

        let report = DiagnosticsCollector(snapshot: snapshot).collect()
        let all = report.entries.map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n")
        for secret in ["OLD_LOG_SECRET", "UNRELATED_LOG_SECRET", "SOURCE_MUST_NOT_BE_READ", "ARCHIVE_MUST_NOT_BE_READ", "SAVE_MUST_NOT_BE_READ", "DOCUMENT_MUST_NOT_BE_READ", "OTHER_APP_CRASH_PRIVATE", "SYMLINK_ESCAPE_PRIVATE", "COMMAND_PRIVATE", "USER_PRINT_PRIVATE", "COMMAND_INPUT_PRIVATE", "GALLERY_PRIVATE", "IGNORED_DEFAULT", "STATUS_PRIVATE", "FILENAME_PRIVATE", "KEY_PRIVATE", "JSON_PRIVATE_TOKEN", "JSON_PRIVATE_COMMAND"] {
            precondition(!all.contains(secret), "Collector included \(secret)")
        }
        precondition(all.contains("LOADER_OK") && all.contains("GAME_CRASH") && all.contains("frame_count"))
        precondition(all.contains("test_hook") && all.contains("CHECK bootstrap pass") && all.contains("player_unavailable"))
        let summary = try JSONSerialization.jsonObject(with: report.entries.first { $0.name == "summary.json" }!.data) as! [String: Any]
        precondition(summary["launcher_version"] as? String == "1.7.0.0", "Four-component version fields are not IP addresses")
        precondition(all.contains("Example/main.reds") && all.contains("Example.archive"), "Inventory lists names without reading content")
        precondition(all.contains("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "SHA-256 of abc matches known digest")
        let graphics = report.entries.first { $0.name == "graphics-settings.json" }!
        precondition(String(decoding: graphics.data, as: UTF8.self).contains("1920x1080"))
        for entry in report.entries where entry.name.hasSuffix(".json") {
            precondition((try? JSONSerialization.jsonObject(with: entry.data)) != nil, "Structured metadata must remain valid JSON")
        }
        print("PASS recent scoped logs, native hash, metadata-only mod inventory and selected graphics settings; excluded saves, sources, unrelated apps and console history")

        try write(game, "red4ext/logs/red4ext-large.log", String(repeating: "x", count: 100_000) + "TAIL_MARKER")
        let tail = scope.read("red4ext/logs/red4ext-large.log", maximum: 128)!
        precondition(tail.count == 128 && String(decoding: tail, as: UTF8.self).hasSuffix("TAIL_MARKER"))
        precondition(scope.hash("red4ext/logs/red4ext-large.log", maximum: 100, deadline: .greatestFiniteMagnitude) == nil)
        var tiny = DiagnosticsLimits(); tiny.totalBytes = 512; tiny.files = 2; tiny.textBytes = 64; tiny.inventoryEntries = 1
        let bounded = DiagnosticsCollector(snapshot: snapshot, limits: tiny).collect()
        precondition(bounded.entries.count <= 2 && bounded.entries.reduce(0) { $0 + $1.data.count } <= 512)
        var narrow = DiagnosticsLimits(); narrow.inventoryEntries = 1
        let inventoryData = DiagnosticsCollector(snapshot: snapshot, limits: narrow).collect().entries.first { $0.name == "mod-inventory.json" }!.data
        let inventoryObject = try JSONSerialization.jsonObject(with: inventoryData) as! [String: Any]
        precondition((inventoryObject["files"] as! [[String: Any]]).count <= 1)
        var limitedJSON = DiagnosticsLimits(); limitedJSON.totalBytes = 1800
        for entry in DiagnosticsCollector(snapshot: snapshot, limits: limitedJSON).collect().entries where entry.name.hasSuffix(".json") {
            precondition((try? JSONSerialization.jsonObject(with: entry.data)) != nil, "A byte cap must omit rather than corrupt structured metadata")
        }
        var expired = DiagnosticsLimits(); expired.seconds = 0
        let fast = DiagnosticsCollector(snapshot: snapshot, limits: expired).collect()
        precondition(!fast.entries.contains { $0.name.hasPrefix("logs/") || $0.name == "native-binaries.json" })
        print("PASS log tail, hashing, total-byte, file-count and expired time-budget limits")

        let zip = fixture.appendingPathComponent("report.zip")
        try report.zipData().write(to: zip)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", zip.path]; try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ZIP is accepted by an independent reader with CRC verification")
        print("PASS exported ZIP structure and all entry CRCs verified by unzip")
    }
}
