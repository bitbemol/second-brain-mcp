import CryptoKit
import Foundation

/// Bytes and modification metadata captured before an optimistic update.
struct FileSnapshot: Sendable {
    /// Exact bytes observed by the reader.
    let data: Data
    /// Best-effort filesystem modification date.
    let modifiedDate: Date?
    /// SHA-256 identity of ``data`` used for caller-visible concurrency checks.
    let revision: FileRevision

    /// Creates an immutable snapshot and derives its exact-byte revision.
    init(data: Data, modifiedDate: Date?) {
        self.data = data
        self.modifiedDate = modifiedDate
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        self.revision = FileRevision(validatedSHA256Hex: digest)
    }
}
