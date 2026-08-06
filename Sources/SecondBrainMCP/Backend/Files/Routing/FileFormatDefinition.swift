/// Complete routing definition for one concrete storage format.
struct FileFormatDefinition: Sendable {
    /// Concrete format selected by the MCP request.
    let format: FileFormat
    /// Effective operation bindings for the format.
    let operations: FormatOperations
}
