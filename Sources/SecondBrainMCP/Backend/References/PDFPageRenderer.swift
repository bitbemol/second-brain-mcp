import AppKit
import Foundation
import PDFKit

/// Renders PDF pages to JPEG images using PDFKit.
/// Struct with static methods — stateless, no concurrency concerns.
///
/// Uses `PDFPage.thumbnail(of:for:)` for rendering, which handles page rotation,
/// cropping, and scaling automatically. Each page is rendered inside its own
/// `autoreleasepool` to limit memory to one page at a time.
///
/// PDFKit creates Objective-C page, image, and text objects during this work. The
/// per-page pool prevents those temporary objects from accumulating across a
/// large selection.
struct PDFPageRenderer {
    /// Renders selected pages from an already-opened PDF document.
    ///
    /// Non-contiguous selections reuse one open document. Text is extracted with
    /// each image so clients receive readable content alongside the page rendering.
    ///
    /// - Parameters:
    ///   - document: Already-opened PDFKit document.
    ///   - pageNumbers: One-based physical pages to render.
    ///   - configuration: Resolution, compression, and dimension policy.
    /// - Returns: Successfully rendered pages in requested order.
    static func renderPages(
        in document: PDFDocument,
        pageNumbers: [Int],
        configuration: PDFRenderConfiguration = .default
    ) -> [RenderedPDFPage] {
        var results: [RenderedPDFPage] = []
        for pageNumber in pageNumbers {
            guard pageNumber > 0, pageNumber <= document.pageCount else { continue }
            let pageIndex = pageNumber - 1

            let rendered: RenderedPDFPage? = autoreleasepool {
                guard let page = document.page(at: pageIndex) else { return nil }

                let label = page.label
                guard let jpegData = Self.jpegData(
                    for: page,
                    configuration: configuration
                ) else {
                    return nil
                }

                // Extract text alongside the image. Detach the string to break the
                // NSString -> PDFPage -> PDFDocument reference chain.
                var text: String? = nil
                if let rawText = page.string, !rawText.isEmpty {
                    var detached = rawText
                    detached.makeContiguousUTF8()
                    text = detached
                }

                return RenderedPDFPage(
                    pageNumber: pageNumber,
                    bookLabel: label,
                    jpegData: jpegData,
                    extractedText: text
                )
            }

            if let rendered {
                results.append(rendered)
            }
        }
        return results
    }

    /// Renders one PDFKit page to bounded JPEG data.
    private static func jpegData(
        for page: PDFPage,
        configuration: PDFRenderConfiguration
    ) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let rasterSize = PDFPageRasterSize(
            pageWidth: bounds.width,
            pageHeight: bounds.height,
            rotation: page.rotation,
            configuration: configuration
        )

        // Use thumbnail(of:for:) which handles rotation, cropping, and scaling
        let thumbnail = page.thumbnail(
            of: NSSize(width: rasterSize.width, height: rasterSize.height),
            for: .mediaBox
        )

        // Convert NSImage to JPEG data
        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: NSNumber(
                    value: Float(configuration.jpegQuality)
                )
            ]
        )
    }
}
