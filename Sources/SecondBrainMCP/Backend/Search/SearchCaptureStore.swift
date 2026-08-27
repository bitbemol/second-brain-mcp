import Foundation

/// Narrower injected limits support bounded callers without increasing production ceilings.
struct SearchCaptureLimits: Sendable {
    static let defaultValue = SearchCaptureLimits()
    static var `default`: Self { defaultValue }
    let maximumBytes: Int
    let maximumFiles: Int
    let maximumManifestBytes: Int

    init(
        maximumBytes: Int = 256 * 1_024 * 1_024,
        maximumFiles: Int = 10_000,
        maximumManifestBytes: Int = 8 * 1_024 * 1_024
    ) {
        precondition((0...256 * 1_024 * 1_024).contains(maximumBytes))
        precondition((0...10_000).contains(maximumFiles))
        precondition((0...8 * 1_024 * 1_024).contains(maximumManifestBytes))
        self.maximumBytes = maximumBytes
        self.maximumFiles = maximumFiles
        self.maximumManifestBytes = maximumManifestBytes
    }
}

/// Private storage failures are request failures, never isolated source failures.
struct SearchCaptureStorageError: Error, Sendable {}

/// One private capture per vault across cooperating processes, without holding vault/PDF permits.
actor SearchCaptureStore {
    private let directory: URL
    private let vaultRoot: URL
    private let processLock: POSIXAdvisoryFileLock
    private let captureObserver: (@Sendable (ReadableFileTarget) -> Void)?
    private let snapshotLoadObserver: (@Sendable (Int) -> Void)?
    private let limits: SearchCaptureLimits
    private var admittedOrWaiting = 0

    init(
        directory: URL,
        vaultRoot: URL,
        processLock: POSIXAdvisoryFileLock? = nil,
        captureObserver: (@Sendable (ReadableFileTarget) -> Void)? = nil,
        snapshotLoadObserver: (@Sendable (Int) -> Void)? = nil,
        limits: SearchCaptureLimits = .default
    ) {
        self.directory = directory
        self.vaultRoot = vaultRoot
        self.processLock = processLock ?? POSIXAdvisoryFileLock(
            url: directory.appendingPathExtension("lock")
        )
        self.captureObserver = captureObserver
        self.snapshotLoadObserver = snapshotLoadObserver
        self.limits = limits
    }

    func withCapture<Result: Sendable>(
        _ operation: @escaping @Sendable (SearchCaptureSession) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard admittedOrWaiting < 33 else { throw VaultSearchRequestError.busy }
        admittedOrWaiting += 1
        defer { admittedOrWaiting -= 1 }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let lease: POSIXAdvisoryFileLock.Lease
        do {
            lease = try await processLock.acquire(.exclusive, deadline: deadline)
        } catch is POSIXAdvisoryFileLock.DeadlineExceeded {
            throw VaultSearchRequestError.busy
        }
        defer { lease.release() }
        try Task.checkCancellation()
        let root = try SearchCaptureDirectory(directory: directory)
        defer { root.close() }
        // Cleanup intentionally ignores task cancellation and precedes new source work.
        try root.removeAbandonedCapture()
        try Task.checkCancellation()
        let session: SearchCaptureSession
        do {
            session = try SearchCaptureSession(
                directory: root, vaultRoot: vaultRoot, observer: captureObserver,
                snapshotLoadObserver: snapshotLoadObserver, limits: limits
            )
        } catch {
            try root.removeAbandonedCapture()
            throw error
        }
        let result: Result
        do {
            result = try await operation(session)
        } catch {
            // A cleanup failure remains fatal and prevents a new capture on next admission.
            try await session.close()
            throw error
        }
        try await session.close()
        return result
    }
}
