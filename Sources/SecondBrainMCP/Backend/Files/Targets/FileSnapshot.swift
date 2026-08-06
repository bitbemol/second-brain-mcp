import Foundation

/// Bytes and modification metadata captured before an optimistic update.
struct FileSnapshot: Sendable {
    /// Exact bytes observed by the reader.
    let data: Data
    /// Best-effort filesystem modification date.
    let modifiedDate: Date?
}
