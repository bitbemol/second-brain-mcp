import CryptoKit
import Foundation

/// Coordinates mutable note paths across tasks and independent MCP processes.
///
/// References bypass this component because they are read-only. Notes use a
/// fair in-process keyed lease plus a persistent cross-process turnstile and
/// resource lock derived from the canonical target path. OS record-lock
/// scheduling provides exclusion, but not strict FIFO order between processes.
struct VaultOperationCoordinator: Sendable {
    private let local = AsyncPathReadWriteCoordinator()
    private let pathLocksURL: URL

    /// Creates a coordinator in an already prepared vault lock directory.
    init(lockDirectoryURL: URL) {
        self.pathLocksURL = lockDirectoryURL.appendingPathComponent(
            "paths",
            isDirectory: true
        )
    }

    /// Runs a notes read concurrently with readers but never a same-path writer.
    func withRead<Result: Sendable>(
        target: ReadableFileTarget,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withAccess(
            canonicalPath: canonicalPath(for: target.url),
            access: .read,
            operation: operation
        )
    }

    /// Runs a complete notes mutation with exclusive same-path access.
    func withWrite<Result: Sendable>(
        target: WritableFileTarget,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withAccess(
            canonicalPath: canonicalPath(for: target.url),
            access: .write,
            operation: operation
        )
    }

    private func withAccess<Result: Sendable>(
        canonicalPath: String,
        access: AsyncPathReadWriteCoordinator.Access,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await local.withAccess(
            key: canonicalPath,
            access: access
        ) {
            let lockStem = lockName(for: canonicalPath)
            let queue = POSIXAdvisoryFileLock(
                url: pathLocksURL.appendingPathComponent(lockStem + ".queue")
            )
            let resource = POSIXAdvisoryFileLock(
                url: pathLocksURL.appendingPathComponent(lockStem + ".resource")
            )

            // Once a contender owns the turnstile, holding it while acquiring
            // the resource prevents new cross-process readers from entering.
            let queueLease = try await queue.acquire(.exclusive)
            let resourceLease: POSIXAdvisoryFileLock.Lease
            do {
                resourceLease = try await resource.acquire(
                    access == .read ? .shared : .exclusive
                )
            } catch {
                queueLease.release()
                throw error
            }
            queueLease.release()
            defer { resourceLease.release() }
            try Task.checkCancellation()
            return try await operation()
        }
    }

    private func canonicalPath(for url: URL) -> String {
        // The default macOS filesystem is case-insensitive and Unicode-aware.
        // Conservatively folding both dimensions prevents two spelling aliases
        // from receiving different lock files. On a case-sensitive volume this
        // may serialize two distinct names, which is safe and only less parallel.
        url.standardized.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private func lockName(for canonicalPath: String) -> String {
        SHA256.hash(data: Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
