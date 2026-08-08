/// Immutable projection of formats accepted by the search service and MCP schema.
struct SearchCapabilities: Equatable, Sendable {
    /// Searchable formats in stable wire order.
    let formats: [FileFormat]
    /// Searchable vault areas in stable wire order.
    let areas: [VaultArea]

    private let formatsByArea: [VaultArea: Set<FileFormat>]

    /// Derives search support from the existing read capability manifest.
    ///
    /// Textual note formats and PDF references are eligible. This keeps one
    /// source of truth for format-area support while excluding broad image
    /// decoding.
    init(fileCapabilities: FileCapabilities) {
        let noteFormats = fileCapabilities
            .supportedFormats(for: .read, in: .notes)
            .filter(\.isTextual)
        let referenceFormats = fileCapabilities
            .supportedFormats(for: .read, in: .references)
            .filter { $0 == .pdf }
        let mapping: [VaultArea: Set<FileFormat>] = [
            .notes: Set(noteFormats),
            .references: Set(referenceFormats),
        ]
        formatsByArea = mapping
        formats = Set(noteFormats + referenceFormats)
            .sorted { $0.rawValue < $1.rawValue }
        areas = VaultArea.allCases.filter {
            !(mapping[$0] ?? []).isEmpty
        }
    }

    /// Returns whether a format is searchable in a concrete vault area.
    func supports(_ format: FileFormat, in area: VaultArea) -> Bool {
        formatsByArea[area]?.contains(format) == true
    }

    /// Searchable formats for one area.
    func formats(in area: VaultArea) -> Set<FileFormat> {
        formatsByArea[area] ?? []
    }
}
