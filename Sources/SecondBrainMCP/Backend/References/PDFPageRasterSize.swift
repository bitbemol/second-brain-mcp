import CoreGraphics

/// Pure pixel dimensions used when rendering one PDF page image.
struct PDFPageRasterSize: Equatable, Sendable {
    /// Output width in pixels.
    let width: CGFloat

    /// Output height in pixels.
    let height: CGFloat

    /// Calculates rotated, resolution-scaled dimensions within the configured cap.
    ///
    /// PDF page bounds are measured in points at 72 points per inch. Quarter-turn
    /// rotations exchange width and height before the long edge is proportionally
    /// reduced to `configuration.maxDimension` when necessary.
    ///
    /// - Parameters:
    ///   - pageWidth: Media-box width in PDF points.
    ///   - pageHeight: Media-box height in PDF points.
    ///   - rotation: PDF page rotation in degrees.
    ///   - configuration: Resolution and output-dimension policy.
    init(
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        rotation: Int,
        configuration: PDFRenderConfiguration
    ) {
        let resolutionScale = configuration.dpi / 72
        var scaledWidth = pageWidth * resolutionScale
        var scaledHeight = pageHeight * resolutionScale

        if rotation == 90 || rotation == 270 {
            swap(&scaledWidth, &scaledHeight)
        }

        let longEdge = max(scaledWidth, scaledHeight)
        if longEdge > configuration.maxDimension {
            let dimensionScale = configuration.maxDimension / longEdge
            scaledWidth *= dimensionScale
            scaledHeight *= dimensionScale
        }

        width = scaledWidth
        height = scaledHeight
    }
}
