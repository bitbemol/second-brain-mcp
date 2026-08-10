import CryptoKit
import Darwin
import Foundation

/// Durable successful-mutation outcomes keyed by caller-generated mutation ID.
///
/// Receipts live outside the vault and are retained indefinitely. This makes a
/// retry after a lost MCP response return the original outcome without applying
/// an append, replacement, create, or deletion twice—even from another process.
/// The journal coordinates cooperating processes and ordinary process crashes;
/// it is not a cross-volume filesystem transaction. Sudden power or storage
/// failure can persist journal records independently from vault bytes or Git.
struct MutationReceiptStore: Sendable {
    struct RetentionLimits: Sendable {
        let maximumReceiptCount: Int
        let maximumAggregateReceiptBytes: Int64
        let identityLockStripeCount: Int
        let maximumReconciliationEntries: Int

        init(
            maximumReceiptCount: Int,
            maximumAggregateReceiptBytes: Int64,
            identityLockStripeCount: Int,
            maximumReconciliationEntries: Int? = nil
        ) {
            self.maximumReceiptCount = maximumReceiptCount
            self.maximumAggregateReceiptBytes = maximumAggregateReceiptBytes
            self.identityLockStripeCount = identityLockStripeCount
            let (defaultEntryLimit, overflow) = maximumReceiptCount
                .addingReportingOverflow(4_096)
            self.maximumReconciliationEntries = maximumReconciliationEntries
                ?? (overflow ? Int.max : defaultEntryLimit)
        }

        static let production = Self(
            maximumReceiptCount: 65_536,
            maximumAggregateReceiptBytes: 512 * 1024 * 1024,
            identityLockStripeCount: 256
        )
    }
    /// Durable state found for one matching mutation request.
    enum Lookup: Sendable {
        /// The mutation completed and its original public result is replayable.
        case completed(FileOperationOutput)
        /// Intent was durably recorded before persistence was allowed to start.
        case prePersistence
        /// Intent includes stable evidence that can disambiguate a directory rename.
        case prePersistenceWithEvidence(VaultMutationRecoveryEvidence)
        /// Persistence may have started before a process stopped. Optional evidence
        /// allows an operation-specific recovery path to inspect the durable state.
        case persistenceStarted(VaultMutationRecoveryEvidence?)
        /// Persistence succeeded but snapshotting failed; retry may record the outcome.
        case failedAfterPersistence(
            output: FileOperationOutput?,
            recoveryEvidence: VaultMutationRecoveryEvidence?,
            failure: String
        )
    }

    /// Receipt corruption or unsafe mutation-ID reuse.
    enum ReceiptError: Error, CustomStringConvertible, Sendable {
        /// One mutation ID was reused for different request bytes.
        case identifierReused(MutationID)
        /// A stored receipt cannot be decoded safely.
        case corrupt(MutationID)
        /// Durable receipt persistence failed before a safe boundary was reached.
        case persistence(path: String, operation: String, code: Int32)
        /// New mutation identities are refused before persistence when retaining
        /// another exact replay outcome would exceed the durable safety bound.
        case capacityExceeded(maximumCount: Int, maximumBytes: Int64)

        var description: String {
            switch self {
            case .identifierReused(let identifier):
                return "Mutation ID \(identifier) was already used for a different request"
            case .corrupt(let identifier):
                return "Stored mutation receipt is corrupt: \(identifier)"
            case .persistence(let path, let operation, let code):
                return "Cannot \(operation) mutation receipt at \(path) (errno \(code))"
            case .capacityExceeded(let maximumCount, let maximumBytes):
                return "Mutation receipt capacity reached (max \(maximumCount) records / \(maximumBytes) bytes); existing exact retries remain available"
            }
        }
    }

    private struct Receipt: Codable {
        enum State: String, Codable, Equatable {
            case inProgress
            case persistenceStarted
            case completed
            case failedAfterPersistence
        }

        let version: Int
        let mutationID: MutationID
        let fingerprint: MutationRequestFingerprint
        let output: FileOperationOutput?
        let recoveryEvidence: VaultMutationRecoveryEvidence?
        let state: State
        let failure: String?
    }

    /// Disposable, crash-durable accounting derived from exact receipts.
    ///
    /// The directory identity makes out-of-band or crash-left receipt changes
    /// invalidate this constant-size summary. `dirty` is persisted before every
    /// owned receipt replacement/removal, so a process death cannot make a stale
    /// clean ledger authoritative.
    private struct QuotaLedger: Codable {
        struct DirectoryStamp: Codable, Equatable {
            let device: UInt64
            let inode: UInt64
            let modificationSeconds: Int64
            let modificationNanoseconds: Int64
            let statusChangeSeconds: Int64
            let statusChangeNanoseconds: Int64
        }

        let version: Int
        let maximumReceiptCount: Int
        let maximumAggregateReceiptBytes: Int64
        let reservedReceiptBytes: Int
        let receiptCount: Int
        let aggregateReservedBytes: Int64
        let directoryStamp: DirectoryStamp
        let dirty: Bool
    }

    private static let maximumReceiptBytes = 1024 * 1024
    // Mutation operations return compact summaries plus metadata, not read
    // payloads. Reserving the full supported encoded outcome at intent admission
    // makes the 512 MiB aggregate and 65,536-record ceilings simultaneously hard.
    private static let reservedReceiptBytes = 8 * 1024
    private static let maximumQuotaLedgerBytes = 64 * 1024
    private static let maximumQuotaRootEntries = 4_096
    static let quotaLedgerFilename = "receipt-quota.json"
    private let receiptDirectoryURL: URL
    private let mutationLockDirectoryURL: URL
    private let receiptUpdateLock: POSIXAdvisoryFileLock
    private let quotaLedgerURL: URL
    private let retentionLimits: RetentionLimits
    private let reconciliationEntryObserver: (@Sendable () -> Void)?

    /// Creates a receipt store in prepared process-owned directories.
    init(
        dataDirectory: VaultDataDirectory,
        retentionLimits: RetentionLimits = .production,
        reconciliationEntryObserver: (@Sendable () -> Void)? = nil
    ) {
        self.receiptDirectoryURL = dataDirectory.receiptDirectoryURL
        self.mutationLockDirectoryURL = dataDirectory.lockDirectoryURL
            .appendingPathComponent("mutations", isDirectory: true)
        self.receiptUpdateLock = POSIXAdvisoryFileLock(
            url: dataDirectory.lockDirectoryURL
                .appendingPathComponent("receipt-updates.lock")
        )
        self.quotaLedgerURL = dataDirectory.rootURL
            .appendingPathComponent(Self.quotaLedgerFilename)
        precondition(retentionLimits.maximumReceiptCount > 0)
        precondition(retentionLimits.maximumAggregateReceiptBytes > 0)
        precondition(retentionLimits.identityLockStripeCount > 0)
        precondition(
            retentionLimits.maximumReconciliationEntries
                >= retentionLimits.maximumReceiptCount
        )
        self.retentionLimits = retentionLimits
        self.reconciliationEntryObserver = reconciliationEntryObserver
    }

    /// Runs a complete attempt under the cross-process identity lock.
    func withIdentityLock<Result: Sendable>(
        _ identifier: MutationID,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let digest = SHA256.hash(data: Data(identifier.rawValue.utf8))
        let stripe = digest.prefix(4).reduce(0) { partial, byte in
            ((partial << 8) | Int(byte))
                % retentionLimits.identityLockStripeCount
        }
        let lock = POSIXAdvisoryFileLock(url: mutationLockDirectoryURL
            .appendingPathComponent(String(format: "identity-%03d.lock", stripe)))
        return try await lock.withLock(.exclusive, operation: operation)
    }

    /// Runs one short receipt or quota-ledger update across all processes.
    ///
    /// Mutation identity locks remain independent, so note persistence can overlap.
    /// Only the small shared accounting transaction is serialized here.
    func updatingReceipt<Result: Sendable>(
        _ operation:
            @escaping @Sendable (MutationReceiptStore) throws -> Result
    ) async throws -> Result {
        let store = self
        return try await receiptUpdateLock.withLock(.exclusive) {
            try operation(store)
        }
    }

    /// Returns the original successful outcome for an identical retry.
    func replay(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) throws -> Lookup? {
        guard let receipt = try loadReceipt(identifier: identifier) else {
            return nil
        }
        guard receipt.fingerprint == fingerprint else {
            throw ReceiptError.identifierReused(identifier)
        }
        switch receipt.state {
        case .inProgress:
            guard receipt.version >= 2 else {
                return .persistenceStarted(receipt.recoveryEvidence)
            }
            if let evidence = receipt.recoveryEvidence {
                return .prePersistenceWithEvidence(evidence)
            }
            return .prePersistence
        case .persistenceStarted:
            return .persistenceStarted(receipt.recoveryEvidence)
        case .completed:
            guard let output = receipt.output,
                  let metadata = output.metadata,
                  metadata.mutationID == identifier else {
                throw ReceiptError.corrupt(identifier)
            }
            return .completed(
                output.withMetadata(metadata.markingReplayed())
            )
        case .failedAfterPersistence:
            guard let failure = receipt.failure else {
                throw ReceiptError.corrupt(identifier)
            }
            return .failedAfterPersistence(
                output: receipt.output,
                recoveryEvidence: receipt.recoveryEvidence,
                failure: failure
            )
        }
    }

    /// Removes an intent that never reached its durable persistence-started state.
    ///
    /// This is safe because persistence may begin only after
    /// ``markPersistenceStarted(identifier:fingerprint:)`` succeeds.
    func clearPrePersistenceIntent(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) throws {
        guard let receipt = try loadReceipt(identifier: identifier),
              receipt.version >= 2,
              receipt.state == .inProgress else {
            throw ReceiptError.corrupt(identifier)
        }
        guard receipt.fingerprint == fingerprint else {
            throw ReceiptError.identifierReused(identifier)
        }
        try removeReceipt(
            identifier: identifier,
            operation: "remove pre-persistence intent"
        )
    }

    /// Reserves one mutation identity before persistence may begin.
    ///
    /// This pre-persistence state is safe to remove and prepare again after a crash.
    func saveInProgress(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint,
        recoveryEvidence: VaultMutationRecoveryEvidence? = nil
    ) throws {
        try write(
            Receipt(
                version: 3,
                mutationID: identifier,
                fingerprint: fingerprint,
                output: nil,
                recoveryEvidence: recoveryEvidence,
                state: .inProgress,
                failure: nil
            ),
            identifier: identifier
        )
    }

    /// Marks the mutation's point of no return without a vault-wide marker.
    ///
    /// Each mutation ID owns its durable state, so unrelated mutations can proceed
    /// concurrently while an exact retry still fails closed after an uncertain crash.
    func markPersistenceStarted(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) throws {
        guard let receipt = try loadReceipt(identifier: identifier),
              receipt.version >= 3,
              receipt.state == .inProgress else {
            throw ReceiptError.corrupt(identifier)
        }
        guard receipt.fingerprint == fingerprint else {
            throw ReceiptError.identifierReused(identifier)
        }
        try write(
            Receipt(
                version: 3,
                mutationID: identifier,
                fingerprint: fingerprint,
                output: nil,
                recoveryEvidence: receipt.recoveryEvidence,
                state: .persistenceStarted,
                failure: nil
            ),
            identifier: identifier
        )
    }

    /// Removes a persistence-started receipt after operation-specific validation
    /// proves that persistence did not occur.
    func clearPersistenceStarted(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) throws {
        guard let receipt = try loadReceipt(identifier: identifier),
              receipt.version >= 3,
              receipt.state == .persistenceStarted else {
            throw ReceiptError.corrupt(identifier)
        }
        guard receipt.fingerprint == fingerprint else {
            throw ReceiptError.identifierReused(identifier)
        }
        try removeReceipt(
            identifier: identifier,
            operation: "remove validated persistence-started receipt"
        )
    }

    /// Atomically persists a replayable successful outcome.
    func save(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint,
        output: FileOperationOutput
    ) throws {
        guard output.metadata?.mutationID == identifier else {
            throw ReceiptError.corrupt(identifier)
        }
        let receipt = Receipt(
            version: 3,
            mutationID: identifier,
            fingerprint: fingerprint,
            output: output,
            recoveryEvidence: nil,
            state: .completed,
            failure: nil
        )
        try write(receipt, identifier: identifier)
    }

    /// Records an outcome that changed bytes but failed during snapshotting.
    func savePostPersistenceFailure(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint,
        output: FileOperationOutput,
        recoveryEvidence: VaultMutationRecoveryEvidence? = nil,
        failure: String
    ) throws {
        guard output.metadata?.mutationID == identifier else {
            throw ReceiptError.corrupt(identifier)
        }
        let receipt = Receipt(
            version: 3,
            mutationID: identifier,
            fingerprint: fingerprint,
            output: output,
            recoveryEvidence: recoveryEvidence,
            state: .failedAfterPersistence,
            failure: failure
        )
        try write(receipt, identifier: identifier)
    }

    private func write(_ receipt: Receipt, identifier: MutationID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= Self.reservedReceiptBytes else {
            throw ReceiptError.capacityExceeded(
                maximumCount: retentionLimits.maximumReceiptCount,
                maximumBytes: retentionLimits.maximumAggregateReceiptBytes
            )
        }
        let destination = receiptURL(for: identifier)
        let existingCharge = try receiptChargeIfPresent(at: destination)
        let ledger = try currentQuotaLedger()
        let nextQuota = try quotaAfterWrite(
            ledger,
            existingCharge: existingCharge
        )
        try persistQuotaLedger(dirtyVersion(of: ledger))
        try DurableMutationRecordIO.write(
            data,
            destination: destination,
            temporaryPrefix: ".\(identifier.rawValue)"
        )
        try persistQuotaLedger(try cleanVersion(
            receiptCount: nextQuota.receiptCount,
            aggregateReservedBytes: nextQuota.aggregateReservedBytes
        ))
    }

    private func receiptURL(for identifier: MutationID) -> URL {
        receiptDirectoryURL.appendingPathComponent(identifier.rawValue + ".json")
    }

    /// Loads the constant-size durable ledger when its directory identity still
    /// matches, otherwise performs one bounded reconciliation. Production calls
    /// this under the short cross-process receipt-update lock.
    private func currentQuotaLedger() throws -> QuotaLedger {
        try cleanupQuotaLedgerTemporaries()
        if let ledger = try loadCurrentQuotaLedger() { return ledger }
        return try reconcileQuotaLedger()
    }

    /// Ledger writes use the same durable atomic-write primitive as receipts.
    /// Its UUID temporaries live beside the ledger rather than among receipts,
    /// so clean them separately with a fixed direct-child work ceiling.
    private func cleanupQuotaLedgerTemporaries() throws {
        let root = quotaLedgerURL.deletingLastPathComponent()
        var encounteredEnumerationError = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                encounteredEnumerationError = true
                return false
            }
        ) else {
            throw persistenceError(path: root.path, operation: "enumerate quota storage")
        }
        var inspectedEntries = 0
        while let url = enumerator.nextObject() as? URL {
            guard inspectedEntries < Self.maximumQuotaRootEntries else {
                throw capacityError()
            }
            inspectedEntries += 1
            guard isQuotaLedgerTemporaryFilename(url.lastPathComponent) else {
                continue
            }
            _ = try validatedFileCharge(at: url)
            guard Darwin.unlink(url.path) == 0 || errno == ENOENT else {
                throw persistenceError(
                    path: url.path,
                    operation: "remove quota temporary"
                )
            }
        }
        guard !encounteredEnumerationError else {
            throw persistenceError(
                path: root.path,
                operation: "enumerate quota storage completely"
            )
        }
    }

    private func quotaAfterWrite(
        _ ledger: QuotaLedger,
        existingCharge: Int64?
    ) throws -> (receiptCount: Int, aggregateReservedBytes: Int64) {
        if let existingCharge {
            // Finalization consumes the reservation established at intent
            // admission, even if the vault is already at its hard ceiling.
            guard ledger.receiptCount > 0,
                  ledger.aggregateReservedBytes >= existingCharge else {
                throw ReceiptError.persistence(
                    path: quotaLedgerURL.path,
                    operation: "apply quota ledger replacement",
                    code: EINVAL
                )
            }
            let reduced = ledger.aggregateReservedBytes - existingCharge
            return (
                ledger.receiptCount,
                reduced + Int64(Self.reservedReceiptBytes)
            )
        }

        let (prospectiveBytes, overflow) = ledger.aggregateReservedBytes
            .addingReportingOverflow(Int64(Self.reservedReceiptBytes))
        guard !overflow,
              ledger.receiptCount < retentionLimits.maximumReceiptCount,
              prospectiveBytes <= retentionLimits.maximumAggregateReceiptBytes else {
            throw capacityError()
        }
        return (ledger.receiptCount + 1, prospectiveBytes)
    }

    private func removeReceipt(
        identifier: MutationID,
        operation: String
    ) throws {
        let destination = receiptURL(for: identifier)
        let existingCharge = try receiptChargeIfPresent(at: destination)
        let ledger = try currentQuotaLedger()
        guard let existingCharge else {
            try DurableMutationRecordIO.remove(destination, operation: operation)
            return
        }
        guard ledger.receiptCount > 0,
              ledger.aggregateReservedBytes >= existingCharge else {
            throw ReceiptError.persistence(
                path: quotaLedgerURL.path,
                operation: "apply quota ledger removal",
                code: EINVAL
            )
        }
        try persistQuotaLedger(dirtyVersion(of: ledger))
        try DurableMutationRecordIO.remove(destination, operation: operation)
        try persistQuotaLedger(try cleanVersion(
            receiptCount: ledger.receiptCount - 1,
            aggregateReservedBytes:
                ledger.aggregateReservedBytes - existingCharge
        ))
    }

    private func loadCurrentQuotaLedger() throws -> QuotaLedger? {
        guard let data = try? DurableMutationRecordIO.read(
            from: quotaLedgerURL,
            maximumBytes: Self.maximumQuotaLedgerBytes,
            displayPath: "mutation receipt quota ledger"
        ) else { return nil }
        guard let ledger = try? JSONDecoder().decode(QuotaLedger.self, from: data)
        else { return nil }
        let (minimumReservedBytes, minimumOverflow) = Int64(ledger.receiptCount)
            .multipliedReportingOverflow(by: Int64(Self.reservedReceiptBytes))
        guard !minimumOverflow,
              ledger.version == 1,
              !ledger.dirty,
              ledger.maximumReceiptCount == retentionLimits.maximumReceiptCount,
              ledger.maximumAggregateReceiptBytes
                == retentionLimits.maximumAggregateReceiptBytes,
              ledger.reservedReceiptBytes == Self.reservedReceiptBytes,
              ledger.receiptCount >= 0,
              ledger.aggregateReservedBytes >= 0,
              ledger.aggregateReservedBytes >= minimumReservedBytes,
              ledger.directoryStamp == (try directoryStamp()) else {
            return nil
        }
        return ledger
    }

    /// Rebuilds accounting with bounded direct-child enumeration. Exact receipts
    /// are never deleted. Recognizable crash-left atomic-write temporaries are
    /// removed only after regular-file ownership/link validation; a temporary
    /// that cannot be removed remains charged to the byte ceiling.
    private func reconcileQuotaLedger() throws -> QuotaLedger {
        var encounteredEnumerationError = false
        guard let enumerator = FileManager.default.enumerator(
            at: receiptDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                encounteredEnumerationError = true
                return false
            }
        ) else {
            throw persistenceError(
                path: receiptDirectoryURL.path,
                operation: "enumerate"
            )
        }

        var inspectedEntries = 0
        var receiptCount = 0
        var aggregateReservedBytes: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard inspectedEntries < retentionLimits.maximumReconciliationEntries else {
                throw capacityError()
            }
            inspectedEntries += 1
            reconciliationEntryObserver?()

            let name = url.lastPathComponent
            if isReceiptFilename(name) {
                let charge = try validatedFileCharge(at: url)
                receiptCount += 1
                aggregateReservedBytes = try addingCharge(
                    charge,
                    to: aggregateReservedBytes
                )
                continue
            }
            guard isCrashTemporaryFilename(name) else { continue }
            let charge = try validatedFileCharge(at: url)
            if Darwin.unlink(url.path) != 0 {
                aggregateReservedBytes = try addingCharge(
                    charge,
                    to: aggregateReservedBytes
                )
            }
        }
        guard !encounteredEnumerationError else {
            throw persistenceError(
                path: receiptDirectoryURL.path,
                operation: "enumerate completely"
            )
        }

        let ledger = try cleanVersion(
            receiptCount: receiptCount,
            aggregateReservedBytes: aggregateReservedBytes
        )
        try persistQuotaLedger(ledger)
        return ledger
    }

    private func receiptChargeIfPresent(at url: URL) throws -> Int64? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw persistenceError(path: url.path, operation: "inspect")
        }
        return try validatedFileCharge(metadata, at: url)
    }

    private func validatedFileCharge(at url: URL) throws -> Int64 {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw persistenceError(path: url.path, operation: "inspect")
        }
        return try validatedFileCharge(metadata, at: url)
    }

    private func validatedFileCharge(
        _ metadata: stat,
        at url: URL
    ) throws -> Int64 {
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumReceiptBytes else {
            throw ReceiptError.persistence(
                path: url.path,
                operation: "account for",
                code: EINVAL
            )
        }
        return max(metadata.st_size, Int64(Self.reservedReceiptBytes))
    }

    private func addingCharge(_ charge: Int64, to total: Int64) throws -> Int64 {
        let (next, overflow) = total.addingReportingOverflow(charge)
        guard !overflow else { throw capacityError() }
        return next
    }

    private func isReceiptFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        return MutationID(rawValue: String(name.dropLast(5))) != nil
    }

    private func isCrashTemporaryFilename(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let body = name.dropFirst().dropLast(4)
        let components = body.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return MutationID(rawValue: String(components[0])) != nil
            && UUID(uuidString: String(components[1])) != nil
    }

    private func isQuotaLedgerTemporaryFilename(_ name: String) -> Bool {
        let prefix = ".receipt-quota."
        guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(
            name.dropFirst(prefix.count).dropLast(4)
        )) != nil
    }

    private func dirtyVersion(of ledger: QuotaLedger) -> QuotaLedger {
        QuotaLedger(
            version: ledger.version,
            maximumReceiptCount: ledger.maximumReceiptCount,
            maximumAggregateReceiptBytes: ledger.maximumAggregateReceiptBytes,
            reservedReceiptBytes: ledger.reservedReceiptBytes,
            receiptCount: ledger.receiptCount,
            aggregateReservedBytes: ledger.aggregateReservedBytes,
            directoryStamp: ledger.directoryStamp,
            dirty: true
        )
    }

    private func cleanVersion(
        receiptCount: Int,
        aggregateReservedBytes: Int64
    ) throws -> QuotaLedger {
        QuotaLedger(
            version: 1,
            maximumReceiptCount: retentionLimits.maximumReceiptCount,
            maximumAggregateReceiptBytes:
                retentionLimits.maximumAggregateReceiptBytes,
            reservedReceiptBytes: Self.reservedReceiptBytes,
            receiptCount: receiptCount,
            aggregateReservedBytes: aggregateReservedBytes,
            directoryStamp: try directoryStamp(),
            dirty: false
        )
    }

    private func directoryStamp() throws -> QuotaLedger.DirectoryStamp {
        var metadata = stat()
        guard Darwin.lstat(receiptDirectoryURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            throw persistenceError(
                path: receiptDirectoryURL.path,
                operation: "inspect receipt directory"
            )
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private func persistQuotaLedger(_ ledger: QuotaLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        guard data.count <= Self.maximumQuotaLedgerBytes else {
            throw persistenceError(
                path: quotaLedgerURL.path,
                operation: "encode quota ledger"
            )
        }
        try DurableMutationRecordIO.write(
            data,
            destination: quotaLedgerURL,
            temporaryPrefix: ".receipt-quota"
        )
    }

    private func capacityError() -> ReceiptError {
        .capacityExceeded(
            maximumCount: retentionLimits.maximumReceiptCount,
            maximumBytes: retentionLimits.maximumAggregateReceiptBytes
        )
    }

    private func persistenceError(path: String, operation: String) -> ReceiptError {
        .persistence(path: path, operation: operation, code: errno == 0 ? EIO : errno)
    }

    /// Loads and validates one supported receipt version without matching input.
    private func loadReceipt(identifier: MutationID) throws -> Receipt? {
        let url = receiptURL(for: identifier)
        guard let data = try DurableMutationRecordIO.read(
            from: url,
            maximumBytes: Self.maximumReceiptBytes,
            displayPath: "mutation receipt \(identifier)"
        ) else { return nil }
        let receipt: Receipt
        do {
            receipt = try JSONDecoder().decode(Receipt.self, from: data)
        } catch {
            throw ReceiptError.corrupt(identifier)
        }
        guard (1...3).contains(receipt.version),
              receipt.mutationID == identifier else {
            throw ReceiptError.corrupt(identifier)
        }
        return receipt
    }

}
