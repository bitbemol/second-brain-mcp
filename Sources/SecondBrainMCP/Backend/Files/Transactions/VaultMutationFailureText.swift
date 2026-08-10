/// Bounds diagnostics before persisting them in recovery receipts.
enum VaultMutationFailureText {
    /// Prevents subprocess diagnostics from producing unbounded transaction data.
    static func bounded(_ error: any Error) -> String {
        String(String(describing: error).prefix(4_096))
    }
}
