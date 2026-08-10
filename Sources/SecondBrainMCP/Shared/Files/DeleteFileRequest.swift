/// Transport-neutral input for a generic soft deletion.
struct DeleteFileRequest: Sendable, Codable {
    /// Revision returned by the read that authorized this deletion.
    let expectedRevision: FileRevision
    /// Declared concrete storage format.
    let format: FileFormat
    /// Existing vault-relative path under `notes/`.
    let path: String
}
