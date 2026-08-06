/// Failures produced while opening a validated PDF reference.
enum PDFReadError: Error, CustomStringConvertible, Sendable {
    /// PDFKit could not open a document at the validated path.
    case cannotOpenPDF(String)

    /// Human-readable PDF reference failure.
    var description: String {
        switch self {
        case .cannotOpenPDF(let path):
            return "Cannot open PDF: \(path)"
        }
    }
}
