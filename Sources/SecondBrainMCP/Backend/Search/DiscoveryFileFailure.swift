import Foundation

/// Only audited, isolated document failures may become incomplete coverage.
enum DiscoveryFileFailure {
    static func reason(for error: any Error) -> DiscoveryCoverage.Reason? {
        switch error {
        case PDFSearchExtractionError.invalidPageCount, PDFSearchExtractionError.missingPage:
            return .invalidDocument
        case PDFSearchExtractionError.pageTextTooLarge, PDFSearchExtractionError.documentTextTooLarge:
            return .fileLimit
        case is SearchAtomProviderError, is CanvasDocumentValidator.ValidationError:
            return .invalidDocument
        case is LinkQuerySourceError, is FileResourcePolicy.Violation:
            return .fileLimit
        case BoundedFileReader.ReadError.changedDuringRead,
             BoundedFileReader.ReadError.notFound,
             VaultFileInspector.InspectionError.notFound:
            return .changedDuringRead
        case let error as POSIXError where error.code == .EACCES || error.code == .EPERM:
            return .unreadable
        case let error as CocoaError where error.code == .fileReadNoPermission:
            return .unreadable
        default:
            return nil
        }
    }
}
