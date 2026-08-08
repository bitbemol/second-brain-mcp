import CryptoKit
import Foundation

/// Coordinates mutable note paths across tasks and independent MCP processes.
///
/// References bypass this component because they are read-only. Notes use a
/// fair in-process keyed lease plus a persistent cross-process turnstile and
/// resource lock derived from the canonical target path. OS record-lock
/// scheduling provides exclusion, but not strict FIFO order between processes.
struct VaultOperationCoordinator: Sendable {
    /// The bounded in-process coordination queue cannot retain another caller.
    struct CapacityExceeded: Error, CustomStringConvertible, Sendable {
        var description: String {
            "Vault file operations are at capacity; retry after an active operation finishes"
        }
    }

    private let local: AsyncPathReadWriteCoordinator
    private let pathLocksURL: URL
    private let treeLockURL: URL
    private let pathLockStripeCount: Int
    private let contentionObserver: (@Sendable () -> Void)?

    /// Creates a coordinator in an already prepared vault lock directory.
    init(
        lockDirectoryURL: URL,
        pathLockStripeCount: Int = 256,
        maximumConcurrentReaders: Int = 128,
        maximumWaitersPerPath: Int = 256,
        maximumTotalWaiters: Int = 1_024,
        contentionObserver: (@Sendable () -> Void)? = nil
    ) {
        self.local = AsyncPathReadWriteCoordinator(
            maximumReadersPerPath: maximumConcurrentReaders,
            maximumWaitersPerPath: maximumWaitersPerPath,
            maximumTotalWaiters: maximumTotalWaiters
        )
        self.pathLocksURL = lockDirectoryURL.appendingPathComponent(
            "paths",
            isDirectory: true
        )
        self.treeLockURL = lockDirectoryURL.appendingPathComponent(
            "notes-tree.resource"
        )
        self.pathLockStripeCount = max(pathLockStripeCount, 1)
        self.contentionObserver = contentionObserver
    }

    /// Runs a notes read concurrently with readers but never a same-path writer.
    func withRead<Result: Sendable>(
        target: ReadableFileTarget,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withTreeAccess(.read) {
            try await withAccess(
                canonicalPath: canonicalPath(for: target.url),
                access: .read,
                operation: operation
            )
        }
    }

    /// Runs a complete notes mutation with exclusive same-path access.
    func withWrite<Result: Sendable>(
        target: WritableFileTarget,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withTreeAccess(.read) {
            try await withAccess(
                canonicalPath: canonicalPath(for: target.url),
                access: .write,
                operation: operation
            )
        }
    }

    /// Excludes every cooperating note read/write while a subtree path changes.
    func withTreeWrite<Result: Sendable>(
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withTreeAccess(.write, operation: operation)
    }

    /// Queued whole-tree leases, exposed for deterministic concurrency tests.
    var waitingTreeOperationCount: Int {
        get async {
            await local.waitingCount(for: "secondbrain://notes-tree")
        }
    }

    private func withTreeAccess<Result: Sendable>(
        _ access: AsyncPathReadWriteCoordinator.Access,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        do {
            return try await local.withAccess(
                key: "secondbrain://notes-tree",
                access: access
            ) {
                let tree = POSIXAdvisoryFileLock(
                    url: treeLockURL,
                    contentionObserver: contentionObserver
                )
                return try await tree.withLock(
                    access == .read ? .shared : .exclusive,
                    operation: operation
                )
            }
        } catch is AsyncPathReadWriteCoordinator.CapacityExceeded {
            throw CapacityExceeded()
        }
    }

    private func withAccess<Result: Sendable>(
        canonicalPath: String,
        access: AsyncPathReadWriteCoordinator.Access,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        do {
            return try await local.withAccess(
                key: canonicalPath,
                access: access
            ) {
                let lockStem = lockStripeName(for: canonicalPath)
                let queue = POSIXAdvisoryFileLock(
                    url: pathLocksURL.appendingPathComponent(lockStem + ".queue"),
                    contentionObserver: contentionObserver
                )
                let resource = POSIXAdvisoryFileLock(
                    url: pathLocksURL.appendingPathComponent(lockStem + ".resource"),
                    contentionObserver: contentionObserver
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
        } catch is AsyncPathReadWriteCoordinator.CapacityExceeded {
            throw CapacityExceeded()
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

    private func lockStripeName(for canonicalPath: String) -> String {
        let prefix = SHA256.hash(data: Data(canonicalPath.utf8)).prefix(8)
        let hashValue = prefix.reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        let stripe = hashValue % UInt64(pathLockStripeCount)
        let digits = String(stripe)
        return "stripe-" + String(
            repeating: "0",
            count: max(4 - digits.count, 0)
        ) + digits
    }
}
