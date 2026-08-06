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
    /// Identity recorded by the vault-wide active-transaction marker.
    struct ActiveTransaction: Equatable, Sendable {
        /// Mutation whose persistence phase may have changed the vault.
        let identifier: MutationID
        /// Exact request identity needed to validate a recovery attempt.
        let fingerprint: MutationRequestFingerprint
    }

    /// Durable state found for one matching mutation request.
    enum Lookup: Sendable {
        /// The mutation completed and its original public result is replayable.
        case completed(FileOperationOutput)
        /// Intent was recorded by the active-marker protocol before persistence.
        case prePersistence
        /// A process stopped after recording intent but before a final outcome.
        case outcomeUnknown
        /// Persistence succeeded but Git failed; retry may commit the saved outcome.
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
        /// The vault-wide active-transaction marker cannot be decoded safely.
        case corruptActiveTransaction
        /// A caller attempted to clear a marker owned by another transaction.
        case activeTransactionChanged(expected: MutationID, actual: MutationID)
        /// Durable receipt persistence failed before a safe boundary was reached.
        case persistence(path: String, operation: String, code: Int32)

        var description: String {
            switch self {
            case .identifierReused(let identifier):
                return "Mutation ID \(identifier) was already used for a different request"
            case .corrupt(let identifier):
                return "Stored mutation receipt is corrupt: \(identifier)"
            case .corruptActiveTransaction:
                return "The active mutation transaction marker is corrupt"
            case .activeTransactionChanged(let expected, let actual):
                return "Active mutation changed from \(expected) to \(actual)"
            case .persistence(let path, let operation, let code):
                return "Cannot \(operation) mutation receipt at \(path) (errno \(code))"
            }
        }
    }

    private struct Receipt: Codable {
        enum State: String, Codable, Equatable {
            case inProgress
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

    /// Minimal vault-wide marker written before any persistence closure runs.
    private struct ActiveMarker: Codable {
        let version: Int
        let mutationID: MutationID
        let fingerprint: MutationRequestFingerprint
    }

    private static let maximumReceiptBytes = 1024 * 1024
    private static let maximumActiveMarkerBytes = 64 * 1024
    private let receiptDirectoryURL: URL
    private let mutationLockDirectoryURL: URL
    private let activeTransactionURL: URL

    /// Creates a receipt store in prepared process-owned directories.
    init(dataDirectory: VaultDataDirectory) {
        self.receiptDirectoryURL = dataDirectory.receiptDirectoryURL
        self.mutationLockDirectoryURL = dataDirectory.lockDirectoryURL
            .appendingPathComponent("mutations", isDirectory: true)
        self.activeTransactionURL = dataDirectory.rootURL
            .appendingPathComponent("active-mutation.json")
    }

    /// Runs a complete attempt under the cross-process identity lock.
    func withIdentityLock<Result: Sendable>(
        _ identifier: MutationID,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let lock = POSIXAdvisoryFileLock(
            url: mutationLockDirectoryURL.appendingPathComponent(
                identifier.rawValue + ".lock"
            )
        )
        return try await lock.withLock(.exclusive, operation: operation)
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
            return receipt.version >= 2 ? .prePersistence : .outcomeUnknown
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

    /// Reads the durable vault-wide marker, if one transaction is active.
    ///
    /// Callers coordinate this method with the vault-wide process lock. A marker
    /// is retained from immediately before persistence until a completed receipt
    /// is durable, preventing an unrelated mutation from obscuring recovery.
    func activeTransaction() throws -> ActiveTransaction? {
        guard let data = try DurableMutationRecordIO.read(
            from: activeTransactionURL,
            maximumBytes: Self.maximumActiveMarkerBytes,
            displayPath: "active mutation transaction"
        ) else { return nil }
        let marker: ActiveMarker
        do {
            marker = try JSONDecoder().decode(ActiveMarker.self, from: data)
        } catch {
            throw ReceiptError.corruptActiveTransaction
        }
        guard marker.version == 1 else {
            throw ReceiptError.corruptActiveTransaction
        }
        return ActiveTransaction(
            identifier: marker.mutationID,
            fingerprint: marker.fingerprint
        )
    }

    /// Persists the vault-wide active marker before persistence may begin.
    func saveActiveTransaction(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) throws {
        let marker = ActiveMarker(
            version: 1,
            mutationID: identifier,
            fingerprint: fingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        guard data.count <= Self.maximumActiveMarkerBytes else {
            throw ReceiptError.corruptActiveTransaction
        }
        try DurableMutationRecordIO.write(
            data,
            destination: activeTransactionURL,
            temporaryPrefix: ".active-mutation"
        )
    }

    /// Durably removes the marker after its completed receipt is visible.
    ///
    /// The expected identity check prevents recovery code from clearing a newer
    /// transaction if this method is ever called without the required process lock.
    func clearActiveTransaction(_ expected: ActiveTransaction) throws {
        guard let current = try activeTransaction() else { return }
        guard current == expected else {
            throw ReceiptError.activeTransactionChanged(
                expected: expected.identifier,
                actual: current.identifier
            )
        }
        try DurableMutationRecordIO.remove(
            activeTransactionURL,
            operation: "remove active transaction"
        )
    }

    /// Clears a crash-left marker only when its receipt is already completed.
    ///
    /// - Returns: `true` when bootstrap is safe, or `false` when an unresolved
    ///   transaction must remain available for request-driven recovery.
    func clearCompletedActiveTransactionForBootstrap() throws -> Bool {
        guard let active = try activeTransaction() else { return true }
        guard let lookup = try replay(
            identifier: active.identifier,
            fingerprint: active.fingerprint
        ) else {
            return false
        }
        guard case .completed = lookup else { return false }
        try clearActiveTransaction(active)
        return true
    }

    /// Removes a version-2 intent when no active marker was ever made durable.
    ///
    /// The executor writes the active marker before calling persistence. Its
    /// absence therefore proves this intent is safe to restart from preparation.
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
        try DurableMutationRecordIO.remove(
            receiptURL(for: identifier),
            operation: "remove pre-persistence intent"
        )
    }

    /// Persists intent immediately before the mutation's point of no return.
    ///
    /// If the process crashes afterward, the surviving marker deliberately
    /// makes a retry fail as outcome-unknown instead of risking a duplicate
    /// append, replacement, creation, or deletion.
    func saveInProgress(
        identifier: MutationID,
        fingerprint: MutationRequestFingerprint
    ) throws {
        try write(
            Receipt(
                version: 2,
                mutationID: identifier,
                fingerprint: fingerprint,
                output: nil,
                recoveryEvidence: nil,
                state: .inProgress,
                failure: nil
            ),
            identifier: identifier
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
            version: 2,
            mutationID: identifier,
            fingerprint: fingerprint,
            output: output,
            recoveryEvidence: nil,
            state: .completed,
            failure: nil
        )
        try write(receipt, identifier: identifier)
    }

    /// Records an outcome that changed bytes but failed during Git sequencing.
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
            version: 2,
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
        guard data.count <= Self.maximumReceiptBytes else {
            throw ReceiptError.corrupt(identifier)
        }
        try DurableMutationRecordIO.write(
            data,
            destination: receiptURL(for: identifier),
            temporaryPrefix: ".\(identifier.rawValue)"
        )
    }

    private func receiptURL(for identifier: MutationID) -> URL {
        receiptDirectoryURL.appendingPathComponent(identifier.rawValue + ".json")
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
        guard (1...2).contains(receipt.version),
              receipt.mutationID == identifier else {
            throw ReceiptError.corrupt(identifier)
        }
        return receipt
    }

}
