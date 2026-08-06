import Foundation

/// Normalized PNG bytes and source metadata ready for generic vault persistence.
struct PreparedImageImport: Sendable {
    /// Normalized PNG bytes.
    let data: Data
    /// Concrete format detected from the source image.
    let sourceFormat: FileFormat
    /// Original source width in pixels.
    let width: Int
    /// Original source height in pixels.
    let height: Int
    /// Optional description of lossy normalization decisions.
    let note: String?
}
