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
        configuration: PDFRenderConfiguration = .default,
        maximumTextBytes: Int = FileReadRequestLimits.maximumPDFRenderedTextBytes,
        maximumPayloadBytes: Int = FileReadRequestLimits
            .maximumPDFRenderedPayloadBytes
            - FileReadRequestLimits.PDFRenderedPayloadEnvelopeBytes
    ) throws -> PDFPageRenderResult {
        var results: [RenderedPDFPage] = []
        var retainedTextBytes = 0
        var retainedPayloadBytes = 0
        var renderFailures = 0
        var payloadOmissions = 0
        var textOmissions = 0
        for pageNumber in pageNumbers {
            try Task.checkCancellation()
            guard pageNumber > 0, pageNumber <= document.pageCount else { continue }
            guard retainedPayloadBytes < max(maximumPayloadBytes, 0) else {
                payloadOmissions += 1
                continue
            }
            let pageIndex = pageNumber - 1
            let remainingTextBytes = max(maximumTextBytes - retainedTextBytes, 0)

            let projection: (
                page: RenderedPDFPage,
                textBytes: Int,
                textOmitted: Bool
            )? = autoreleasepool {
                guard let page = document.page(at: pageIndex) else { return nil }

                let label = Self.boundedMetadata(page.label)
                guard let jpegData = Self.jpegData(
                    for: page,
                    configuration: configuration
                ) else {
                    return nil
                }

                // Extract text alongside the image. Detach the string to break the
                // NSString -> PDFPage -> PDFDocument reference chain.
                var text: String? = nil
                var textBytes = 0
                var textOmitted = false
                if page.numberOfCharacters > remainingTextBytes {
                    textOmitted = page.numberOfCharacters > 0
                } else if let rawText = page.string, !rawText.isEmpty {
                    var detached = rawText
                    detached.makeContiguousUTF8()
                    let bytes = detached.utf8.count
                    if bytes <= remainingTextBytes {
                        text = Self.displaySafeText(detached)
                        textBytes = bytes
                    } else {
                        textOmitted = true
                    }
                }

                return (
                    RenderedPDFPage(
                        pageNumber: pageNumber,
                        bookLabel: label,
                        jpegData: jpegData,
                        extractedText: text
                    ),
                    textBytes,
                    textOmitted
                )
            }
            // A native PDFKit render cannot be interrupted mid-call, but a
            // canceled request never begins another expensive page.
            try Task.checkCancellation()

            guard let projection else {
                renderFailures += 1
                continue
            }
            let pagePayloadBytes = Self.base64EncodedByteCount(
                projection.page.jpegData.count
            ) + (projection.textBytes * 2)
                + (projection.page.bookLabel?.utf8.count ?? 0) * 2 + 256
            guard pagePayloadBytes <= maximumPayloadBytes - retainedPayloadBytes else {
                payloadOmissions += 1
                continue
            }
            results.append(projection.page)
            retainedTextBytes += projection.textBytes
            retainedPayloadBytes += pagePayloadBytes
            if projection.textOmitted { textOmissions += 1 }
        }
        return PDFPageRenderResult(
            pages: results,
            renderFailureCount: renderFailures,
            payloadOmissionCount: payloadOmissions,
            textOmissionCount: textOmissions,
            retainedPayloadBytes: retainedPayloadBytes
        )
    }

    private static func base64EncodedByteCount(_ bytes: Int) -> Int {
        guard bytes > 0 else { return 0 }
        return ((bytes + 2) / 3) * 4
    }

    private static func boundedMetadata(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let result = PDFDisplayText.bounded(value, maximumBytes: 512)
        return result.isEmpty ? nil : result
    }

    private static func displaySafeText(_ value: String) -> String {
        PDFDisplayText.sanitized(value)
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
