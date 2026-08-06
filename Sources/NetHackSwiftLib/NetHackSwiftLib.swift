import NetHackBridge

public enum Nethack {
    /// Run NetHack. Suspends the calling task until the game ends.
    /// - Parameter arguments: Command-line arguments (e.g. `["-u", "Alice"]`).
    /// - Returns: NetHack's exit code.
    @discardableResult
    public static func run(arguments: [String] = []) async -> Int32 {
        await withCheckedContinuation { continuation in
            NetHackBridge().run(withArguments: arguments) { exitCode in
                continuation.resume(returning: exitCode)
            }
        }
    }
}
