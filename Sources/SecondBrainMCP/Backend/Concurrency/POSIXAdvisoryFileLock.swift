import Darwin
import Foundation

/// Cancellation-aware advisory lock backed by a persistent regular file.
///
/// Lock acquisition always uses a nonblocking open-file-description record
/// lock; contention suspends with `Task.sleep` rather than blocking a Swift
/// cooperative executor thread.
struct POSIXAdvisoryFileLock: Sendable {
    /// Shared-reader or exclusive-writer mode.
    enum Mode: Sendable {
        case shared
        case exclusive
    }

    /// Failures opening or locking the process-owned lock file.
    struct LockError: Error, CustomStringConvertible, Sendable {
        let path: String
        let operation: String
        let code: Int32

        var description: String {
            "Cannot \(operation) coordination lock at \(path) (errno \(code))"
        }
    }

    /// Optional admission deadline expired before the lock was acquired.
    struct DeadlineExceeded: Error, Sendable {}

    /// Held descriptor whose close releases the advisory lock after crashes too.
    final class Lease: @unchecked Sendable {
        private let mutex = NSLock()
        private let path: String
        private var descriptor: Int32?

        fileprivate init(descriptor: Int32, path: String) {
            self.path = path
            self.descriptor = descriptor
        }

        /// Releases the lock and closes its descriptor exactly once.
        func release() {
            mutex.lock()
            let current = descriptor
            descriptor = nil
            mutex.unlock()
            guard let current else { return }
            // Closing is the release operation for an OFD lock. Do not issue
            // F_UNLCK: a spawned child may share this open-file description
            // specifically so the lock survives a killed parent until the
            // child itself exits.
            _ = Darwin.close(current)
        }

        /// Descriptor marked as inherited by one protected child process.
        private func descriptorForChildInheritance() throws -> Int32 {
            mutex.lock()
            defer { mutex.unlock() }
            guard let descriptor else {
                throw LockError(path: path, operation: "inherit", code: EBADF)
            }
            return descriptor
        }

        /// Adds the held open-file description to one child's spawn actions.
        func addChildInheritance(
            to fileActions: inout posix_spawn_file_actions_t?
        ) throws {
            let descriptor = try descriptorForChildInheritance()
            // Unlike dup2 to a magic descriptor, addinherit has no source/
            // destination collision and clears FD_CLOEXEC for this spawn even
            // when POSIX_SPAWN_CLOEXEC_DEFAULT is active.
            let status = posix_spawn_file_actions_addinherit_np(
                &fileActions,
                descriptor
            )
            guard status == 0 else {
                throw LockError(path: path, operation: "inherit", code: status)
            }
        }

        deinit { release() }
    }

    private let url: URL
    private let descriptorOpener: (@Sendable () throws -> Int32)?
    private let retryNanoseconds: UInt64
    private let contentionObserver: (@Sendable () -> Void)?

    /// Creates a lock adapter for one persistent process-owned file.
    init(
        url: URL,
        descriptorOpener: (@Sendable () throws -> Int32)? = nil,
        retryNanoseconds: UInt64 = 20_000_000,
        contentionObserver: (@Sendable () -> Void)? = nil
    ) {
        self.url = url
        self.descriptorOpener = descriptorOpener
        self.retryNanoseconds = retryNanoseconds
        self.contentionObserver = contentionObserver
    }

    /// Acquires a shared or exclusive lease without blocking an executor thread.
    func acquire(
        _ mode: Mode,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> Lease {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw DeadlineExceeded() }
        let descriptor: Int32
        if let descriptorOpener {
            descriptor = try descriptorOpener()
        } else {
            descriptor = Darwin.open(
                url.path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw LockError(path: url.path, operation: "open", code: errno)
        }

        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else {
                throw LockError(path: url.path, operation: "validate", code: errno)
            }

            let lockType = mode == .shared ? Int16(F_RDLCK) : Int16(F_WRLCK)
            while Self.setLock(descriptor: descriptor, type: lockType) != 0 {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN || code == EACCES else {
                    throw LockError(path: url.path, operation: "acquire", code: code)
                }
                contentionObserver?()
                try Task.checkCancellation()
                if let deadline {
                    let now = ContinuousClock.now
                    guard now < deadline else { throw DeadlineExceeded() }
                    let delay = min(now.advanced(by: .nanoseconds(Int64(clamping: retryNanoseconds))), deadline)
                    try await ContinuousClock().sleep(until: delay)
                } else {
                    try await Task.sleep(nanoseconds: retryNanoseconds)
                }
            }
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw DeadlineExceeded() }
            return Lease(descriptor: descriptor, path: url.path)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Runs an operation while holding one advisory lease.
    func withLock<Result: Sendable>(
        _ mode: Mode,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let lease = try await acquire(mode)
        defer { lease.release() }
        return try await operation()
    }

    /// Applies a nonblocking open-file-description lock to the whole file.
    ///
    /// Darwin's Swift overlay exposes `flock` as the record-lock structure and
    /// not the same-named C function. `F_OFD_SETLK` also has better semantics
    /// here: each lease belongs to its exact open descriptor, so closing one of
    /// several concurrent shared-reader descriptors cannot release the others.
    private static func setLock(descriptor: Int32, type: Int16) -> Int32 {
        var record = flock()
        record.l_type = type
        record.l_whence = Int16(SEEK_SET)
        record.l_start = 0
        record.l_len = 0
        return Darwin.fcntl(descriptor, F_OFD_SETLK, &record)
    }
}

extension POSIXAdvisoryFileLock.Mode: Equatable {}
