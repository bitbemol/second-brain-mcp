import Foundation

/// Filesystem metadata shared by validated regular-file trust boundaries.
struct RegularFileMetadata: Sendable {
    /// File size reported by the filesystem.
    let byteCount: Int
    /// Last modification date, when supplied by the filesystem.
    let modificationDate: Date?
    /// Stable descriptor facts used to avoid rehashing an unchanged search file.
    let deviceID: UInt64?
    let inode: UInt64?
    let modificationNanoseconds: Int64?
    let changeSeconds: Int64?
    let changeNanoseconds: Int64?

    init(
        byteCount: Int,
        modificationDate: Date?,
        deviceID: UInt64? = nil,
        inode: UInt64? = nil,
        modificationNanoseconds: Int64? = nil,
        changeSeconds: Int64? = nil,
        changeNanoseconds: Int64? = nil
    ) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.deviceID = deviceID
        self.inode = inode
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }
}
