import CryptoKit
import Foundation

/// Bytes and modification metadata captured before an optimistic update.
struct FileSnapshot: Sendable {
    typealias RevisionProvider = @Sendable (Data) -> FileRevision

    /// Exact bytes observed by the reader.
    let data: Data
    /// Best-effort filesystem modification date.
    let modifiedDate: Date?
    /// Lazily memoized SHA-256 identity of the exact data used for concurrency checks.
    var revision: FileRevision {
        revisionCache.resolve(data)
    }

    private let revisionCache: RevisionCache

    /// Creates an immutable snapshot without hashing until its revision is needed.
    init(
        data: Data,
        modifiedDate: Date?,
        revisionProvider: @escaping RevisionProvider = Self.sha256Revision
    ) {
        self.data = data
        self.modifiedDate = modifiedDate
        self.revisionCache = RevisionCache(provider: revisionProvider)
    }

    private static func sha256Revision(_ data: Data) -> FileRevision {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return FileRevision(validatedSHA256Hex: digest)
    }

    /// Synchronizes the one-time digest without making the immutable snapshot actor-bound.
    private final class RevisionCache: @unchecked Sendable {
        private let lock = NSLock()
        private let provider: RevisionProvider
        private var cachedRevision: FileRevision?

        init(provider: @escaping RevisionProvider) {
            self.provider = provider
        }

        func resolve(_ data: Data) -> FileRevision {
            lock.withLock {
                if let cachedRevision {
                    return cachedRevision
                }
                let resolved = provider(data)
                cachedRevision = resolved
                return resolved
            }
        }
    }
}
