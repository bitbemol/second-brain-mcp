import AppKit
import Foundation
import PDFKit

/// Renders bounded physical PDF pages as display-safe text plus PNG images.
enum PDFPageRenderer {
    /// Renders every requested page in order or fails the complete read.
    static func renderPages(
        in document: PDFDocument,
        pageNumbers: [Int],
        configuration: PDFRenderConfiguration = .default,
        maximumTextBytes: Int = FileReadRequestLimits.maximumPDFRenderedTextBytes,
        maximumPayloadBytes: Int = FileReadRequestLimits
            .maximumPDFRenderedPayloadBytes
            - FileReadRequestLimits.PDFRenderedPayloadEnvelopeBytes
    ) throws -> [RenderedPDFPage] {
        let pageTextLimit = max(maximumTextBytes, 0) / max(pageNumbers.count, 1)
        var result: [RenderedPDFPage] = []
        result.reserveCapacity(pageNumbers.count)
        var retainedPayloadBytes = 0

        for pageNumber in pageNumbers {
            try Task.checkCancellation()
            guard pageNumber > 0, pageNumber <= document.pageCount else {
                throw PDFReadError.pageOutOfBounds(
                    page: pageNumber,
                    totalPages: document.pageCount
                )
            }

            let rendered: RenderedPDFPage? = autoreleasepool {
                guard let page = document.page(at: pageNumber - 1),
                      let pngData = pngData(for: page, configuration: configuration) else {
                    return nil
                }
                var rawText = page.string ?? ""
                rawText.makeContiguousUTF8()
                return RenderedPDFPage(
                    pageNumber: pageNumber,
                    text: PDFDisplayText.bounded(
                        rawText,
                        maximumBytes: pageTextLimit
                    ),
                    pngData: pngData
                )
            }
            try Task.checkCancellation()
            guard let rendered else {
                throw PDFReadError.cannotRenderPage(pageNumber)
            }

            let pagePayloadBytes = base64EncodedByteCount(rendered.pngData.count)
                + rendered.text.utf8.count * 2
                + 256
            guard pagePayloadBytes <= max(maximumPayloadBytes, 0) - retainedPayloadBytes else {
                throw PDFReadError.responseTooLarge(maximumBytes: maximumPayloadBytes)
            }
            result.append(rendered)
            retainedPayloadBytes += pagePayloadBytes
        }
        return result
    }

    private static func base64EncodedByteCount(_ bytes: Int) -> Int {
        guard bytes > 0 else { return 0 }
        return ((bytes + 2) / 3) * 4
    }

    /// Renders one complete PDF page as a bounded PNG.
    private static func pngData(
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
        let thumbnail = page.thumbnail(
            of: NSSize(width: rasterSize.width, height: rasterSize.height),
            for: .mediaBox
        )
        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
