/// Serializes expensive direct PDF reads and bounds suspended callers.
///
/// The permit covers the private snapshot and all PDFKit work, so one process
/// cannot retain several 512 MiB temporary copies at once. An optional advisory
/// lock extends the same bound across MCP processes serving one vault.
struct PDFReadAdmission: Sendable {
    private let gate: AsyncExclusiveGate
    private let processLock: POSIXAdvisoryFileLock?

    /// Creates a PDF-read admission boundary.
    init(
        maximumQueuedRequests: Int = 32,
        gate: AsyncExclusiveGate? = nil,
        processLock: POSIXAdvisoryFileLock? = nil
    ) {
        self.gate = gate ?? AsyncExclusiveGate(
            maximumWaiters: maximumQueuedRequests
        )
        self.processLock = processLock
    }

    /// Runs one complete direct PDF read while holding the shared permit.
    func withPermit<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        do {
            return try await gate.withPermit {
                if let processLock {
                    return try await processLock.withLock(
                        .exclusive,
                        operation: operation
                    )
                }
                return try await operation()
            }
        } catch is AsyncExclusiveGate.CapacityExceeded {
            throw PDFReadError.busy
        }
    }
}
