import Foundation

/// The two useful representations of one physical PDF page.
struct RenderedPDFPage: Sendable {
    /// One-based physical page number.
    let pageNumber: Int
    /// Bounded, display-safe embedded text. Empty for image-only pages.
    let text: String
    /// Bounded PNG representation of the complete page.
    let pngData: Data
}
