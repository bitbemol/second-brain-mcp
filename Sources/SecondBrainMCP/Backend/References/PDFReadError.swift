/// Failures produced while opening a validated PDF reference.
enum PDFReadError: Error, CustomStringConvertible, Sendable {
    /// PDFKit could not open a document at the validated path.
    case cannotOpenPDF(String)
    /// The direct text query is empty or exceeds its bounded input policy.
    case invalidQuery(maximumBytes: Int)
    /// A page selector is empty or exceeds its public UTF-8 ceiling.
    case invalidSelector(name: String, maximumBytes: Int)
    /// The bounded queue already contains the maximum number of PDF reads.
    case busy
    /// Printed-label lookup exceeded its bounded page scan.
    case pageLabelSearchIncomplete(maximumPages: Int)

    /// Human-readable PDF reference failure.
    var description: String {
        switch self {
        case .cannotOpenPDF(let path):
            return "Cannot open PDF: \(path)"
        case .invalidQuery(let maximumBytes):
            return "PDF query must contain text and use at most \(maximumBytes) UTF-8 bytes"
        case .invalidSelector(let name, let maximumBytes):
            return "PDF \(name) must contain text and use at most \(maximumBytes) UTF-8 bytes"
        case .busy:
            return "PDF reader is busy; retry this request later"
        case .pageLabelSearchIncomplete(let maximumPages):
            return "PDF page-label lookup stopped after \(maximumPages) pages; use a physical page or range"
        }
    }
}
