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

    static let full = DiscoveryCoverage(
        complete: true, failedFiles: nil, samples: nil, samplesTruncated: nil
    )

    private enum CodingKeys: String, CodingKey {
        case complete, samples
        case failedFiles = "failed_files"
        case samplesTruncated = "samples_truncated"
    }
}
