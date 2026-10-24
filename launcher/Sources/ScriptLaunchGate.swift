import Foundation

enum ScriptLaunchGate {
    /// A 2.5 cached bundle may declare natives absent from the currently verified plugins.
    /// Never launch that stale cache after compilation failed; retain the older 2.3.1 fallback.
    static func launch(gameVersion: String?, compilationError: String?, action: () -> Void) -> String? {
        if gameVersion == "2.5.0", let error = compilationError {
            return "Can't launch because scripts failed to compile: \(error). Fix the reported script conflict and try Play again."
        }
        action()
        return nil
    }
}
