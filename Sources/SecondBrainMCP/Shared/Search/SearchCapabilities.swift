/// Immutable projection of formats accepted by the search service and MCP schema.
struct SearchCapabilities: Equatable, Sendable {
    /// Searchable note formats in stable wire order.
    let formats: [FileFormat]

    /// Derives search support from the existing read capability manifest.
    ///
    /// Only textual formats readable from `notes/` are eligible. This keeps one
    /// source of truth for format-area support and excludes binary decoding from
    /// broad search.
    init(fileCapabilities: FileCapabilities) {
        formats = fileCapabilities
            .supportedFormats(for: .read, in: .notes)
            .filter(\.isTextual)
            .sorted { $0.rawValue < $1.rawValue }
    }
}
