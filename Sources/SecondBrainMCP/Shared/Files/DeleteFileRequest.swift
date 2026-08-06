/// Transport-neutral input for a generic soft deletion.
struct DeleteFileRequest: Sendable {
    /// Declared concrete storage format.
    let format: FileFormat
    /// Existing vault-relative path under `notes/`.
    let path: String
}
