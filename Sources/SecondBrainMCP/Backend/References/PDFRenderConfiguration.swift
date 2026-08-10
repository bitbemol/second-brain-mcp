import CoreGraphics

/// Bounded rasterization policy for PDF page images.
struct PDFRenderConfiguration: Sendable {
    /// Target rendering resolution in dots per inch.
    let dpi: CGFloat
    /// Maximum output pixel dimension for unusually large pages.
    let maxDimension: CGFloat

    /// Readable production settings with a bounded long edge.
    static let `default` = PDFRenderConfiguration(
        dpi: 150,
        maxDimension: 2_000
    )
}
