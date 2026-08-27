/// Completeness of the observed eligible corpus, independent of result pagination.
struct DiscoveryCoverage: Codable, Equatable, Sendable {
    struct Failure: Codable, Equatable, Sendable {
        let path: String
        let reason: Reason
    }

    enum Reason: String, Codable, CaseIterable, Sendable {
        case invalidDocument = "invalid_document"
        case fileLimit = "file_limit"
        case unreadable
        case changedDuringRead = "changed_during_read"
    }

    let complete: Bool
    let failedFiles: Int?
    let samples: [Failure]?
    let samplesTruncated: Bool?
    /// Search-only exact failure counts; keys are stable concrete format names.
    let failedByFormat: [String: Int]?
    /// On incomplete search, eligible formats whose entire representation was examined.
    let completeFormats: [String]?

    init(complete: Bool, failedFiles: Int?, samples: [Failure]?, samplesTruncated: Bool?,
         failedByFormat: [String: Int]? = nil, completeFormats: [String]? = nil) {
        self.complete = complete
        self.failedFiles = failedFiles
        self.samples = samples
        self.samplesTruncated = samplesTruncated
        self.failedByFormat = failedByFormat
        self.completeFormats = completeFormats
    }

    static let full = DiscoveryCoverage(
        complete: true, failedFiles: nil, samples: nil, samplesTruncated: nil
    )

    private enum CodingKeys: String, CodingKey {
        case complete, samples
        case failedFiles = "failed_files"
        case failedByFormat = "failed_by_format"
        case completeFormats = "complete_formats"
        case samplesTruncated = "samples_truncated"
    }
}
