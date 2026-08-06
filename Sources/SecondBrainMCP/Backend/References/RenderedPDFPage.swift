import Foundation

/// One rendered, user-facing PDF page.
struct RenderedPDFPage: Sendable {
    /// One-based physical page number.
    let pageNumber: Int
    /// Printed page label, such as `xii` or `42`, when available.
    let bookLabel: String?
    /// JPEG representation of the rendered page.
    let jpegData: Data
    /// Extracted page text, or `nil` for scanned and image-only pages.
    let extractedText: String?
}
