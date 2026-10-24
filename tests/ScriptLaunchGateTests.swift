import Foundation

@main
struct ScriptLaunchGateTests {
    static func main() {
        var launches = 0
        let failure = "Duplicate class TweakDBManager"
        let error = ScriptLaunchGate.launch(gameVersion: "2.5.0", compilationError: failure) { launches += 1 }
        precondition(launches == 0, "A failed 2.5 compile must not start the game")
        precondition(error?.contains(failure) == true, "The original compiler diagnostic must reach the player")
        precondition(ScriptLaunchGate.launch(gameVersion: "2.5.0", compilationError: nil) { launches += 1 } == nil)
        precondition(launches == 1, "A successful 2.5 compile starts the game once")
        precondition(ScriptLaunchGate.launch(gameVersion: "2.3.1", compilationError: failure) { launches += 1 } == nil)
        precondition(launches == 2, "The existing 2.3.1 cached-script fallback must remain available")
        print("PASS 2.5 compile failures block the launch action and retain diagnostics; successful compiles and 2.3.1 fallback launch once")
    }
}
