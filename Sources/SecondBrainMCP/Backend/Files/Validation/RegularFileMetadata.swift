import Foundation

/// Filesystem metadata shared by validated regular-file trust boundaries.
struct RegularFileMetadata: Sendable {
    /// File size reported by the filesystem.
    let byteCount: Int
    /// Last modification date, when supplied by the filesystem.
    let modificationDate: Date?
}
