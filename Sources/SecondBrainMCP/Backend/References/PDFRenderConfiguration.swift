import CoreGraphics

/// Rendering and compression policy for PDF page images.
struct PDFRenderConfiguration: Sendable {
    /// Target rendering resolution in dots per inch.
    let dpi: CGFloat
    /// JPEG compression quality from maximum compression at `0` to `1`.
    let jpegQuality: CGFloat
    /// Maximum output pixel dimension for unusually large pages.
    let maxDimension: CGFloat

    /// Balanced production settings for readable, bounded page images.
    static let `default` = PDFRenderConfiguration(
        dpi: 150,
        jpegQuality: 0.6,
        maxDimension: 2000
    )
}
