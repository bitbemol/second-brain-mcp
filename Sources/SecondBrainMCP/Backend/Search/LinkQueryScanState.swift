import CryptoKit
import Foundation

/// Backend execution ceilings, separate from public request/page limits.
enum LinkQueryExecutionLimits {
    static let maximumSourceBytes = 256 * 1_024 * 1_024
    static let maximumIndexedFiles = 10_000
    static let maximumScannedEntries = 100_000
    static let maximumOccurrences = 100_000
    static let maximumResolutionCandidates = 1_000_000
    static let maximumCachedTargets = 128
    static let maximumCachedCandidates = 4_096
}

/// Incremental, length-delimited identity of the observed graph inputs.
struct LinkQueryFingerprint {
    private var hasher = SHA256()

    init() { append("link-query-observed-input-v2") }

    mutating func append(_ value: String) {
        var count = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
        hasher.update(data: Data(value.utf8))
    }

    var digest: String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Retains only one requested page and a continuation sentinel while counting all results.
struct LinkQueryPageAccumulator {
    let offset: Int
    let limit: Int
    private(set) var count = 0
    private(set) var observedAnchor: String?
    private(set) var page: [LinkQueryResult] = []

    mutating func append(_ result: LinkQueryResult) throws {
        if count == offset - 1 {
            observedAnchor = try LinkQueryCursorCodec.anchorHash(result)
        }
        if count >= offset, page.count < limit + 1 { page.append(result) }
        count += 1
    }

    func response(
        request: LinkQueryRequest,
        requestHash: String,
        fingerprint: String,
        cursor: LinkQueryCursorCodec.Payload?,
        coverage: DiscoveryCoverage
    ) throws -> LinkQueryResponse {
        if let cursor {
            guard cursor.corpusHash == fingerprint else { throw LinkQueryError.staleCursor }
            guard offset < count, observedAnchor == cursor.anchorHash else {
                throw LinkQueryError.invalidCursor
            }
        }
        let returned = Array(page.prefix(limit))
        let nextCursor: String?
        if page.count > returned.count, let last = returned.last {
            nextCursor = try LinkQueryCursorCodec.encode(
                requestHash: requestHash, corpusHash: fingerprint,
                offset: offset + returned.count,
                anchorHash: LinkQueryCursorCodec.anchorHash(last)
            )
        } else {
            nextCursor = nil
        }
        return LinkQueryResponse(
            direction: request.direction, results: returned,
            nextCursor: nextCursor, coverage: coverage
        )
    }
}
