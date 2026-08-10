import CoreGraphics
import Testing
@testable import second_brain_mcp

@Suite("PDF page raster sizing")
struct PDFPageRasterSizeTests {
    @Test("Converts PDF points to pixels at the configured resolution")
    func appliesResolution() {
        let size = PDFPageRasterSize(
            pageWidth: 612,
            pageHeight: 792,
            rotation: 0,
            configuration: configuration(dpi: 144, maximumDimension: 2_000)
        )

        #expect(size.width == 1_224)
        #expect(size.height == 1_584)
    }

    @Test("Quarter-turn rotations exchange pixel dimensions")
    func appliesQuarterTurnRotation() {
        let configuration = configuration(dpi: 144, maximumDimension: 2_000)
        let clockwise = PDFPageRasterSize(
            pageWidth: 612,
            pageHeight: 792,
            rotation: 90,
            configuration: configuration
        )
        let counterclockwise = PDFPageRasterSize(
            pageWidth: 612,
            pageHeight: 792,
            rotation: 270,
            configuration: configuration
        )

        #expect(clockwise.width == 1_584)
        #expect(clockwise.height == 1_224)
        #expect(counterclockwise == clockwise)
    }

    @Test("Long-edge capping preserves the page aspect ratio")
    func capsLongEdgeProportionally() {
        let size = PDFPageRasterSize(
            pageWidth: 1_000,
            pageHeight: 2_000,
            rotation: 0,
            configuration: configuration(dpi: 72, maximumDimension: 1_000)
        )

        #expect(size.width == 500)
        #expect(size.height == 1_000)
    }

    @Test("Half-turn rotations retain the original orientation")
    func retainsOrientationForHalfTurn() {
        let configuration = configuration(dpi: 72, maximumDimension: 2_000)
        let unrotated = PDFPageRasterSize(
            pageWidth: 600,
            pageHeight: 800,
            rotation: 0,
            configuration: configuration
        )
        let halfTurn = PDFPageRasterSize(
            pageWidth: 600,
            pageHeight: 800,
            rotation: 180,
            configuration: configuration
        )

        #expect(halfTurn == unrotated)
    }

    private func configuration(
        dpi: CGFloat,
        maximumDimension: CGFloat
    ) -> PDFRenderConfiguration {
        PDFRenderConfiguration(
            dpi: dpi,
            jpegQuality: 0.6,
            maxDimension: maximumDimension
        )
    }
}
