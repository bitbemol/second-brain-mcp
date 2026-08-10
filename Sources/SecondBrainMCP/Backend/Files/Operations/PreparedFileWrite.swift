import Foundation

/// Validated bytes and presentation output prepared by a format operation.
///
/// Create and update handlers produce the same backend value: bytes ready for
/// generic persistence plus output returned only after persistence and vault
/// snapshotting succeed. Keeping this type in Backend prevents mutation mechanics
/// from leaking into the shared transport contract.
struct PreparedFileWrite: Sendable {
    /// Exact bytes passed to the generic persistence boundary.
    let data: Data
    /// Result returned after persistence and vault snapshotting succeed.
    let output: FileOperationOutput
}
