import Foundation

/// Extracts typed flight evidence only. Never returns console text, commands,
/// character names, arbitrary state names, coordinates, or unrecognized reasons.
enum FlightDiagnosticSummary {
    private static let maximumBytes = 128 * 1024
    private static let maximumLines = 512
    private static let maximumEntries = 16
    private static let runtimeReady = "==== MINI-CET v3 (universal call + perks/attrs/relic) ready ===="
    private static let waits: Set<String> = ["same-time", "context-or-capture", "position-unavailable", "None"]
    private static let booleans: Set<String> = ["active", "arrivalPending", "arrivalUnconfirmed", "restoreUnconfirmed", "recoveryUsed"]
    private static let counters: Set<String> = ["arrivalSerial", "ticks", "inputChecks", "captureWrites", "filterWrites",
        "velocityWrites", "positionWritesIssued", "positionReadbacks", "positionRefusals", "checkpointQueries"]
    private static let distances: Set<String> = ["positionReadbackDistance", "positionOriginDivergence",
        "maxPositionReadbackDistance", "maxPositionOriginDivergence", "maxObservedEntityRadiusMeters", "lastIssuedTargetRadiusMeters"]
    private static let reasons: [String: String] = [
        "Original zero-preset state replaced queued cleanup ownership": "original_zero_takeover",
        "Queued relocation cleanup needs a fresh normal filter from the current owner": "cleanup_capture_unavailable",
        "Queued relocation cleanup refused: submitting locomotion state changed": "cleanup_state_changed",
        "Queued arrival observation refused: player owner changed": "arrival_owner_changed",
        "Queued arrival observation refused: invalid simulation time": "arrival_invalid_time",
        "Queued arrival observation reached its 0.5-second or 64-callback limit": "arrival_timeout",
        "Queued arrival observation refused: current normal locomotion context is not confirmed": "arrival_context_unavailable",
        "Queued arrival observation refused: player left normal locomotion": "arrival_player_state_unsupported",
        "Queued arrival observation refused: invalid physics position type": "arrival_invalid_position_type",
        "Queued arrival observation refused: invalid observed coordinates": "arrival_invalid_coordinates",
        "Position refused: invalid frame delta": "movement_invalid_delta",
        "Position refused: physics Position is not a defined Vector4": "movement_position_unavailable",
        "Position refused: invalid or out-of-bounds current position": "movement_invalid_position",
        "Position refused: physics/entity origins diverged by more than 0.25m": "movement_origin_divergence",
        "Position refused: prior target is more than 1m from physics readback": "movement_readback_mismatch",
        "Position refused: activation physics/entity origin delta exceeds 0.01m": "movement_activation_origin_mismatch",
        "Position refused: invalid camera movement vectors": "movement_invalid_camera",
        "Position refused: invalid movement vector": "movement_invalid_vector",
        "Position refused: movement step exceeds 0.6m": "movement_step_limit",
        "Position refused: target exceeds finite world-coordinate bounds": "movement_world_bounds",
        "Position refused: current interface changed before write": "movement_interface_changed",
        "Position refused: guarded native bridge did not issue the write": "movement_write_refused",
        "Restored normal collision for locomotion exit": "locomotion_exit",
        "Forced locomotion exit": "forced_locomotion_exit",
        "Return requested to the activation point": "return_requested",
        "Queued relocation arrival observed with normal collision; press Start again for a new flight": "arrival_confirmed",
        "Normal collision restored; queued arrival remains unconfirmed; Start can request a read-only recheck": "arrival_unconfirmed",
        "Stopped here; normal gravity resumes; filter restored": "stopped_here"
    ]

    static func parse(_ text: String) -> [String: Any] {
        let truncated = text.utf8.count > maximumBytes
        var bounded = String(decoding: text.utf8.suffix(maximumBytes), as: UTF8.self)
        if truncated, let newline = bounded.firstIndex(of: "\n") {
            bounded.removeSubrange(bounded.startIndex...newline)
        } else if truncated { bounded = "" }
        let lines = bounded.split(separator: "\n", omittingEmptySubsequences: false)
        let boundary = lines.lastIndex(where: { $0 == runtimeReady })
        let scoped = boundary.map { lines[lines.index(after: $0)...] } ?? lines[...]
        var entries: [[String: Any]] = []
        var rejected = 0
        for part in scoped.suffix(maximumLines) {
            let line = String(part)
            guard line.hasPrefix("[Flight] ") || line.hasPrefix("[Stored relocation] ") else { continue }
            let limit = line.hasPrefix("[Stored relocation] ") ? 4096 : 8192
            guard line.utf8.count <= limit, !sensitive(line),
                  line.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { rejected += 1; continue }
            let entry = line.hasPrefix("[Flight] ") ? status(line) : relocation(line)
            guard let entry else { rejected += 1; continue }
            entries.append(entry)
            if entries.count > maximumEntries { entries.removeFirst() }
        }
        return ["schema": 1, "entries": entries, "entry_limit": maximumEntries,
                "input_truncated": truncated, "line_window_truncated": scoped.count > maximumLines,
                "boundary_found": boundary != nil,
                "scope": boundary != nil ? "after_latest_runtime_ready_marker" : "bounded_tail_unscoped",
                "rejected_candidate_lines": rejected]
    }

    private static func sensitive(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["password", "passwd", "secret", "authorization", "bearer", "api_key", "api-key", "apikey",
                "token", "private key", "/users/", "/volumes/", "https://", "http://"].contains { lowered.contains($0) }
            || value.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: .regularExpression) != nil
    }

    private static func boolean(_ value: String) -> Bool? {
        value == "true" ? true : value == "false" ? false : nil
    }

    private static func integer(_ value: String, maximum: Int = 2_147_483_647) -> Int? {
        guard !value.isEmpty, value.utf8.count <= 10, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let result = Int(value), result <= maximum else { return nil }
        return result
    }

    private static func number(_ value: String, minimum: Double = 0, maximum: Double = 1_000_000_000) -> Double? {
        guard !value.isEmpty, value.utf8.count <= 32,
              value.range(of: "^-?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let result = Double(value), result.isFinite, result >= minimum, result <= maximum else { return nil }
        return result
    }

    private static func category(_ reason: String) -> String? {
        if let value = reasons[reason] { return value }
        for suffix in ["; recovery requested to the latest clear position", "; emergency recovery to the activation point",
                       "; arrival unconfirmed; Start can request a read-only recheck after collision cleanup"] where reason.hasSuffix(suffix) {
            return reasons[String(reason.dropLast(suffix.count))]
        }
        return nil
    }

    private static func status(_ line: String) -> [String: Any]? {
        guard let start = line.range(of: "; active=") else { return nil }
        var result: [String: Any] = ["kind": "status"]
        if let reason = category(String(line[line.index(line.startIndex, offsetBy: 9)..<start.lowerBound])) {
            result["category"] = reason
        }
        var seen: Set<String> = []
        for component in line[start.upperBound...].split(separator: ";", omittingEmptySubsequences: false).enumerated() {
            let field = (component.offset == 0 ? "active=" : "") + component.element.trimmingCharacters(in: .whitespaces)
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = String(field[..<separator]), value = String(field[field.index(after: separator)...])
            let recognized = booleans.contains(key) || counters.contains(key) || distances.contains(key)
                || ["elapsedSeconds", "arrivalCallbacks", "arrivalElapsed", "arrivalDistance", "arrivalTolerance"].contains(key)
            guard recognized else { continue }
            guard seen.insert(key).inserted else { return nil }
            if booleans.contains(key) {
                guard let parsed = boolean(value) else { return nil }; result[key] = parsed
            } else if counters.contains(key) {
                guard let parsed = integer(value) else { return nil }; result[key] = parsed
            } else if key == "arrivalCallbacks" {
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[1] == "64", let parsed = integer(String(parts[0]), maximum: 64) else { return nil }
                result[key] = parsed
            } else if key == "arrivalElapsed" {
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[1] == "0.5", let parsed = number(String(parts[0])) else { return nil }
                result[key] = parsed
            } else {
                let minimum: Double = key == "arrivalDistance" ? -1 : 0
                let maximum: Double = key == "arrivalTolerance" ? 0.25 : key == "elapsedSeconds" ? 1_000_000_000 : 400_000
                guard let parsed = number(value, minimum: minimum, maximum: maximum) else { return nil }; result[key] = parsed
            }
        }
        // Full native status always carries these independent cleanup facts.
        guard booleans.isSubset(of: seen) else { return nil }
        return result
    }

    private static func relocation(_ line: String) -> [String: Any]? {
        let keys = ["serial", "cause", "lastOwnedState", "control", "queuedExit", "processingExit", "paused/requested",
            "flags/menu", "issuedAt", "capture", "submitted", "destination", "origin", "priorTarget",
            "priorReadbackPending/distance/originError", "tolerance", "latestFailure", "failureCallbacks/seconds",
            "observationWait", "lastValidObservation", "observedState", "entity", "physics", "distance",
            "now[pending/active/restoreUnconfirmed/callbacks/seconds]"]
        guard line.hasPrefix("[Stored relocation] serial=") else { return nil }
        var cursor = line.index(line.startIndex, offsetBy: "[Stored relocation] serial=".count)
        var fields: [String: String] = [:]
        for (index, key) in keys.enumerated() {
            if index + 1 == keys.count { fields[key] = String(line[cursor...]); break }
            guard let marker = line.range(of: " " + keys[index + 1] + "=", range: cursor..<line.endIndex) else { return nil }
            fields[key] = String(line[cursor..<marker.lowerBound]); cursor = marker.upperBound
        }
        guard let serial = integer(fields["serial"]!), let capture = integer(fields["capture"]!),
              let issuedAt = number(fields["issuedAt"]!), let tolerance = number(fields["tolerance"]!, maximum: 0.25),
              let distance = number(fields["distance"]!, minimum: -1, maximum: 400_000),
              let queuedExit = integer(fields["queuedExit"]!, maximum: 2),
              let processingExit = integer(fields["processingExit"]!, maximum: 2),
              waits.contains(fields["observationWait"]!) else { return nil }
        guard fields["cause"]!.utf8.count <= 256, fields["latestFailure"]!.utf8.count <= 256,
              fields["lastOwnedState"]!.utf8.count <= 129, fields["observedState"]!.utf8.count <= 129,
              ["start", "stop-here", "return", "resume", "None"].contains(fields["control"]!) else { return nil }
        let pause = fields["paused/requested"]!.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let flags = fields["flags/menu"]!.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let prior = fields["priorReadbackPending/distance/originError"]!.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let observed = fields["lastValidObservation"]!.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard pause.count == 2, pause.allSatisfy({ boolean($0) != nil }), flags.count == 2,
              (flags[0] == "-1" || integer(flags[0], maximum: 255) != nil), boolean(flags[1]) != nil,
              prior.count == 3, boolean(prior[0]) != nil, number(prior[1], maximum: 400_000) != nil,
              number(prior[2], maximum: 400_000) != nil, observed.count == 2, boolean(observed[0]) != nil,
              number(observed[1]) != nil else { return nil }
        let state = fields[keys.last!]!.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let failure = fields["failureCallbacks/seconds"]!.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard state.count == 5, let pending = boolean(state[0]), let active = boolean(state[1]), let restore = boolean(state[2]),
              let callbacks = integer(state[3], maximum: 64), let elapsed = number(state[4]),
              failure.count == 2, let failureCallbacks = integer(failure[0], maximum: 64), let failureElapsed = number(failure[1]) else { return nil }
        // Coordinate strings are validated but deliberately never exported.
        for key in ["submitted", "destination", "origin", "priorTarget", "entity", "physics"] {
            let parts = fields[key]!.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ number(String($0), minimum: -100_000, maximum: 100_000) != nil }) else { return nil }
        }
        var result: [String: Any] = ["kind": "stored_relocation", "arrivalSerial": serial, "captureWrites": capture,
            "control": fields["control"]!, "queuedExit": queuedExit, "processingExit": processingExit,
            "issuedAt": issuedAt, "arrivalTolerance": tolerance, "arrivalDistance": distance, "arrivalPending": pending,
            "active": active, "restoreUnconfirmed": restore, "arrivalUnconfirmed": true, "arrivalCallbacks": callbacks,
            "arrivalElapsed": elapsed, "failureCallbacks": failureCallbacks, "failureElapsed": failureElapsed,
            "observationWait": fields["observationWait"]!]
        if let reason = category(fields["cause"]!) { result["cause_category"] = reason }
        if let reason = category(fields["latestFailure"]!) { result["failure_category"] = reason }
        return result
    }
}
