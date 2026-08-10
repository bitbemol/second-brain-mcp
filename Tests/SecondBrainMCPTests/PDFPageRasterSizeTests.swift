import CoreGraphics
import Testing
@testable import second_brain_mcp

@Suite
struct `PDF page raster sizing` {
    @Test
    func `Converts PDF points to pixels at the configured resolution`() {
        let size = PDFPageRasterSize(
            pageWidth: 612,
            pageHeight: 792,
            rotation: 0,
            configuration: configuration(dpi: 144, maximumDimension: 2_000)
        )

        #expect(size.width == 1_224)
        #expect(size.height == 1_584)
    }

    @Test
    func `Quarter-turn rotations exchange pixel dimensions`() {
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

    @Test
    func `Long-edge capping preserves the page aspect ratio`() {
        let size = PDFPageRasterSize(
            pageWidth: 1_000,
            pageHeight: 2_000,
            rotation: 0,
            configuration: configuration(dpi: 72, maximumDimension: 1_000)
        )

        #expect(size.width == 500)
        #expect(size.height == 1_000)
    }

    @Test
    func `Half-turn rotations retain the original orientation`() {
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
            maxDimension: maximumDimension
        )
    }
}
