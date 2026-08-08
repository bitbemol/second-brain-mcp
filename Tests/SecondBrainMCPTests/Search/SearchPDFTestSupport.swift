import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Creates an in-memory, text-bearing PDF for search tests. No external or
/// copyrighted PDF fixture is stored in the repository.
func generatedSearchPDF(
    pages: [String],
    title: String = "Generated Search Fixture"
) throws -> Data {
    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output) else {
        throw GeneratedPDFError.cannotCreate
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let metadata = [kCGPDFContextTitle as String: title] as CFDictionary
    guard let context = CGContext(
        consumer: consumer,
        mediaBox: &mediaBox,
        metadata
    ) else {
        throw GeneratedPDFError.cannotCreate
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
    ]
    for text in pages {
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 54, y: 54, width: 504, height: 684), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.endPDFPage()
    }
    context.closePDF()
    return output as Data
}

/// Creates an in-memory password-protected PDF for metadata-status tests.
func generatedLockedSearchPDF(
    pages: [String],
    title: String = "Generated Locked Search Fixture"
) throws -> Data {
    guard let document = PDFDocument(data: try generatedSearchPDF(
        pages: pages,
        title: title
    )) else {
        throw GeneratedPDFError.cannotCreate
    }
    let options: [AnyHashable: Any] = [
        PDFDocumentWriteOption.userPasswordOption: "generated-user-password",
        PDFDocumentWriteOption.ownerPasswordOption: "generated-owner-password",
    ]
    guard let data = document.dataRepresentation(options: options),
          PDFDocument(data: data)?.isLocked == true else {
        throw GeneratedPDFError.cannotCreate
    }
    return data
}

private enum GeneratedPDFError: Error {
    case cannotCreate
}
