import Foundation

@main
struct FlightDiagnosticSummaryTests {
    static let status = "[Flight] Queued relocation arrival observed with normal collision; press Start again for a new flight; active=false; arrivalPending=false; arrivalUnconfirmed=false; restoreUnconfirmed=false; recoveryUsed=false; arrivalSerial=3; arrivalCallbacks=2/64; arrivalElapsed=0.0234/0.5; arrivalDistance=0; arrivalTolerance=0.2500; elapsedSeconds=4.981; ticks=208; positionWritesIssued=208; positionReadbacks=207; positionReadbackDistance=0.0063; positionOriginDivergence=0; maxPositionReadbackDistance=0.1089; maxPositionOriginDivergence=0; positionRefusals=0; state=MyCustomLocomotionName; custom=PERSONAL_VALUE"
    static let relocation = "[Stored relocation] serial=1 cause=Restored normal collision for locomotion exit; recovery requested to the latest clear position lastOwnedState=Locomotion/MyCustomState control=stop-here queuedExit=0 processingExit=0 paused/requested=true/true flags/menu=0/false issuedAt=82657.0000 capture=56 submitted=-1380.0000,1272.0000,123.0000 destination=-1381.1312,1272.2324,123.1084 origin=0.0000,0.0000,0.0000 priorTarget=-1380.0000,1272.0000,123.0000 priorReadbackPending/distance/originError=true/0.0068/0.0000 tolerance=0.2500 latestFailure=Queued arrival observation reached its 0.5-second or 64-callback limit failureCallbacks/seconds=23/0.5078 observationWait=context-or-capture lastValidObservation=false@0.0000 observedState=None/None entity=0.0000,0.0000,0.0000 physics=0.0000,0.0000,0.0000 distance=-1.0000 now[pending/active/restoreUnconfirmed/callbacks/seconds]=false/false/false/23/0.5078"

    static func entries(_ text: String) -> [[String: Any]] {
        FlightDiagnosticSummary.parse(text)["entries"] as! [[String: Any]]
    }
    static func json(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: FlightDiagnosticSummary.parse(text), options: [.sortedKeys]), as: UTF8.self)
    }

    static func main() throws {
        let accepted = entries(status)
        precondition(accepted.count == 1)
        let first = accepted[0]
        precondition(first["kind"] as? String == "status" && first["category"] as? String == "arrival_confirmed")
        precondition(first["active"] as? Bool == false && first["arrivalUnconfirmed"] as? Bool == false)
        precondition(first["arrivalCallbacks"] as? Int == 2 && first["positionWritesIssued"] as? Int == 208)
        precondition(first["arrivalElapsed"] as? Double == 0.0234)
        let stored = entries(relocation)
        precondition(stored.count == 1)
        precondition(stored[0]["cause_category"] as? String == "locomotion_exit")
        precondition(stored[0]["failure_category"] as? String == "arrival_timeout")
        precondition(stored[0]["observationWait"] as? String == "context-or-capture")
        precondition(stored[0]["arrivalUnconfirmed"] as? Bool == true && stored[0]["arrivalDistance"] as? Double == -1)
        precondition(stored[0]["control"] as? String == "stop-here")
        precondition(stored[0]["queuedExit"] as? Int == 0 && stored[0]["processingExit"] as? Int == 0)
        let queued = entries(relocation.replacingOccurrences(of: "queuedExit=0 processingExit=0", with: "queuedExit=1 processingExit=0"))[0]
        let processing = entries(relocation.replacingOccurrences(of: "queuedExit=0 processingExit=0", with: "queuedExit=0 processingExit=1"))[0]
        precondition(queued["queuedExit"] as? Int == 1 && queued["processingExit"] as? Int == 0)
        precondition(processing["queuedExit"] as? Int == 0 && processing["processingExit"] as? Int == 1)
        let exported = try json(status + "\n" + relocation)
        for excluded in ["PERSONAL_VALUE", "MyCustomLocomotionName", "MyCustomState", "Locomotion/", "-1381.1312", "latest clear position"] {
            precondition(!exported.contains(excluded), "raw report value leaked")
        }
        print("PASS current status and stored relocation become typed, bounded fields without raw state names or coordinates")

        let unrelated = """
        > print('COMMAND_PRIVATE')
        queued: Game.PrivateCommand()
        [Flight] some arbitrary command response PERSONAL_VALUE
        [NotFlight] active=false; arrivalPending=false
        [Flight] start requested
        """
        precondition(entries(unrelated).isEmpty)
        let unrelatedJSON = try json(unrelated)
        precondition(!unrelatedJSON.contains("COMMAND_PRIVATE"))
        for credential in [" password=PRIVATE", " api_key=PRIVATE", " authorization: Bearer PRIVATE", " token = PRIVATE",
                           " email=person@private.invalid", " path=/Users/alice/private"] {
            precondition(entries(status + credential).isEmpty)
            precondition(entries(relocation.replacingOccurrences(of: "cause=", with: "cause=" + credential + " ")).isEmpty)
        }
        let unknownReason = relocation.replacingOccurrences(of: "Queued arrival observation reached its 0.5-second or 64-callback limit", with: "UNRECOGNIZED_CAUSE")
        precondition(entries(unknownReason)[0]["failure_category"] == nil)
        let unknownJSON = try json(unknownReason)
        precondition(!unknownJSON.contains("UNRECOGNIZED_CAUSE"))
        print("PASS command history, credential-like lines, and unknown reason strings are excluded")

        for replacement in ["nan", "inf", "1e309", "-1", "2147483648", "5junk", ""] {
            precondition(entries(status.replacingOccurrences(of: "ticks=208", with: "ticks=" + replacement)).isEmpty)
        }
        for malformed in [status + "; active=true", status.replacingOccurrences(of: "active=false", with: "active=yes"),
                          status.replacingOccurrences(of: "arrivalCallbacks=2/64", with: "arrivalCallbacks=65/64"),
                          status.replacingOccurrences(of: "arrivalElapsed=0.0234/0.5", with: "arrivalElapsed=0.0234/99"),
                          status.replacingOccurrences(of: "arrivalTolerance=0.2500", with: "arrivalTolerance=99"),
                          status.replacingOccurrences(of: "; recoveryUsed=false", with: ""),
                          relocation.replacingOccurrences(of: "context-or-capture", with: "ARBITRARY_WAIT"),
                          relocation.replacingOccurrences(of: "control=stop-here", with: "control=ARBITRARY_CONTROL"),
                          relocation.replacingOccurrences(of: "paused/requested=true/true", with: "paused/requested=bad"),
                          relocation.replacingOccurrences(of: "entity=0.0000,0.0000,0.0000", with: "entity=NaN,0,0"),
                          String(relocation.dropLast(20)), status + "\tbad"] {
            precondition(entries(malformed).isEmpty, "malformed candidate accepted")
        }
        print("PASS invalid numeric fields, duplicate keys, malformed structure, and non-ASCII-control content are rejected")

        precondition(entries(status + String(repeating: "x", count: 8193)).isEmpty)
        precondition(entries(relocation + String(repeating: "x", count: 4097)).isEmpty)
        let repeated = (0..<40).map { status.replacingOccurrences(of: "arrivalSerial=3", with: "arrivalSerial=\($0)") }.joined(separator: "\n")
        let bounded = entries(repeated)
        precondition(bounded.count == 16 && bounded.first?["arrivalSerial"] as? Int == 24 && bounded.last?["arrivalSerial"] as? Int == 39)
        let long = FlightDiagnosticSummary.parse(String(repeating: "UNRELATED_PRIVATE\n", count: 15000) + status)
        precondition(long["input_truncated"] as? Bool == true)
        precondition((long["entries"] as! [[String: Any]]).count == 1)
        precondition(entries(String(repeating: "x", count: 150000)).isEmpty)
        for wait in ["same-time", "position-unavailable", "None"] {
            precondition(entries(relocation.replacingOccurrences(of: "context-or-capture", with: wait))[0]["observationWait"] as? String == wait)
        }
        print("PASS bounded input, line lengths, entry count, and fixed wait enumeration")

        let marker = "==== MINI-CET v3 (universal call + perks/attrs/relic) ready ===="
        let scoped = FlightDiagnosticSummary.parse(relocation + "\n" + marker + "\n" + status)
        let scopedEntries = scoped["entries"] as! [[String: Any]]
        precondition(scoped["boundary_found"] as? Bool == true)
        precondition(scoped["scope"] as? String == "after_latest_runtime_ready_marker")
        precondition(scopedEntries.count == 1 && scopedEntries[0]["kind"] as? String == "status")
        let latest = FlightDiagnosticSummary.parse(marker + "\n" + relocation + "\n" + marker + "\n")
        precondition((latest["entries"] as! [[String: Any]]).isEmpty)
        for absent in [status, String(marker.dropFirst(10)) + "\n" + status,
                       marker + String(repeating: "\nunrelated", count: 20000) + "\n" + status] {
            let unscoped = FlightDiagnosticSummary.parse(absent)
            precondition(unscoped["boundary_found"] as? Bool == false)
            precondition(unscoped["scope"] as? String == "bounded_tail_unscoped")
        }
        print("PASS exact latest startup marker excludes prior-launch reports without inferring a PID")
    }
}
