import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Mutation receipt retention")
struct MutationReceiptStoreRetentionTests {
    @Test("Durable accounting makes saves constant-work after reconciliation")
    func quotaAccountingDoesNotRescanPerSave() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptScaleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: vault,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: vault) }
        let dataDirectory = try makeTestDataDirectory(vaultPath: vault.path)
        let limits = MutationReceiptStore.RetentionLimits(
            maximumReceiptCount: 256,
            maximumAggregateReceiptBytes: 4 * 1024 * 1024,
            identityLockStripeCount: 4
        )
        let seed = MutationReceiptStore(
            dataDirectory: dataDirectory,
            retentionLimits: limits
        )
        for index in 0..<64 {
            let identifier = MutationID()
            try seed.save(
                identifier: identifier,
                fingerprint: .init(rawValue: "seed-\(index)"),
                output: output(identifier: identifier, text: "seed")
            )
        }
        try FileManager.default.removeItem(
            at: dataDirectory.rootURL.appendingPathComponent(
                MutationReceiptStore.quotaLedgerFilename
            )
        )

        let counter = ReceiptReconciliationCounter()
        let store = MutationReceiptStore(
            dataDirectory: dataDirectory,
            retentionLimits: limits,
            reconciliationEntryObserver: { counter.increment() }
        )
        let first = MutationID()
        try store.save(
            identifier: first,
            fingerprint: .init(rawValue: "first-after-bootstrap"),
            output: output(identifier: first, text: "first")
        )
        let bootstrapWork = counter.value
        #expect(bootstrapWork == 64)

        let second = MutationID()
        try store.save(
            identifier: second,
            fingerprint: .init(rawValue: "second-after-bootstrap"),
            output: output(identifier: second, text: "second")
        )
        #expect(counter.value == bootstrapWork)
    }

    @Test("Crash-left receipt temporaries are removed before quota admission")
    func crashTemporaryIsCleanedAndDoesNotConsumeQuota() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptTemporaryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: vault,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: vault) }
        let dataDirectory = try makeTestDataDirectory(vaultPath: vault.path)
        let store = MutationReceiptStore(
            dataDirectory: dataDirectory,
            retentionLimits: .init(
                maximumReceiptCount: 2,
                maximumAggregateReceiptBytes: 16 * 1024,
                identityLockStripeCount: 2
            )
        )
        let first = MutationID()
        try store.save(
            identifier: first,
            fingerprint: .init(rawValue: "first"),
            output: output(identifier: first, text: "first")
        )
        let temporary = dataDirectory.receiptDirectoryURL.appendingPathComponent(
            ".\(MutationID().rawValue).\(UUID().uuidString).tmp"
        )
        try Data(repeating: 0x61, count: 8 * 1024).write(to: temporary)
        let ledgerTemporary = dataDirectory.rootURL.appendingPathComponent(
            ".receipt-quota.\(UUID().uuidString).tmp"
        )
        try Data(repeating: 0x62, count: 512).write(to: ledgerTemporary)

        let second = MutationID()
        try store.save(
            identifier: second,
            fingerprint: .init(rawValue: "second"),
            output: output(identifier: second, text: "second")
        )

        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: ledgerTemporary.path))
        #expect(throws: MutationReceiptStore.ReceiptError.self) {
            try store.saveInProgress(
                identifier: MutationID(),
                fingerprint: .init(rawValue: "over-quota")
            )
        }
    }

    @Test("Receipt reconciliation work is bounded even with unexpected entries")
    func reconciliationEntryWorkIsBounded() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptReconciliationBound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: vault,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: vault) }
        let dataDirectory = try makeTestDataDirectory(vaultPath: vault.path)
        for index in 0..<3 {
            try Data().write(to: dataDirectory.receiptDirectoryURL
                .appendingPathComponent("unexpected-\(index)"))
        }
        let counter = ReceiptReconciliationCounter()
        let store = MutationReceiptStore(
            dataDirectory: dataDirectory,
            retentionLimits: .init(
                maximumReceiptCount: 2,
                maximumAggregateReceiptBytes: 16 * 1024,
                identityLockStripeCount: 2,
                maximumReconciliationEntries: 2
            ),
            reconciliationEntryObserver: { counter.increment() }
        )

        #expect(throws: MutationReceiptStore.ReceiptError.self) {
            try store.saveInProgress(
                identifier: MutationID(),
                fingerprint: .init(rawValue: "bounded")
            )
        }
        #expect(counter.value == 2)
    }

    @Test("Hard quota refuses new identities while exact retained retries remain")
    func quotaFailsClosedWithoutPruningReceipts() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptQuotaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: vault,
            withIntermediateDirectories: false
        )
        let dataDirectory = try makeTestDataDirectory(vaultPath: vault.path)
        let limits = MutationReceiptStore.RetentionLimits(
            maximumReceiptCount: 2,
            maximumAggregateReceiptBytes: 1024 * 1024,
            identityLockStripeCount: 4
        )
        let store = MutationReceiptStore(
            dataDirectory: dataDirectory,
            retentionLimits: limits
        )
        let first = MutationID()
        let second = MutationID()
        let firstFingerprint = MutationRequestFingerprint(rawValue: "first")
        try store.save(
            identifier: first,
            fingerprint: firstFingerprint,
            output: output(identifier: first, text: "first")
        )
        try store.saveInProgress(
            identifier: second,
            fingerprint: MutationRequestFingerprint(rawValue: "second")
        )

        #expect(throws: MutationReceiptStore.ReceiptError.self) {
            try store.saveInProgress(
                identifier: MutationID(),
                fingerprint: MutationRequestFingerprint(rawValue: "third")
            )
        }
        guard case .completed(let replayed)? = try store.replay(
            identifier: first,
            fingerprint: firstFingerprint
        ) else {
            Issue.record("Expected the retained exact receipt")
            return
        }
        #expect(replayed.metadata?.replayed == true)

        // Finalization consumes the reservation established at admission and
        // must remain possible even when no new identity can be admitted.
        try store.save(
            identifier: second,
            fingerprint: MutationRequestFingerprint(rawValue: "second"),
            output: output(identifier: second, text: "second")
        )
    }

    @Test("Identity locks use a fixed stripe set instead of one file per UUID")
    func identityLocksHaveBoundedCardinality() async throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: vault,
            withIntermediateDirectories: false
        )
        let dataDirectory = try makeTestDataDirectory(vaultPath: vault.path)
        let store = MutationReceiptStore(
            dataDirectory: dataDirectory,
            retentionLimits: .init(
                maximumReceiptCount: 100,
                maximumAggregateReceiptBytes: 16 * 1024 * 1024,
                identityLockStripeCount: 4
            )
        )

        for _ in 0..<100 {
            _ = try await store.withIdentityLock(MutationID()) { true }
        }

        let directory = dataDirectory.lockDirectoryURL
            .appendingPathComponent("mutations")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("identity-") && $0.hasSuffix(".lock") }
        #expect(names.count <= 4)
    }

    private func output(
        identifier: MutationID,
        text: String
    ) -> FileOperationOutput {
        .text(text).withMetadata(FileOperationMetadata(
            path: "notes/receipt.md",
            area: .notes,
            revision: nil,
            mutationID: identifier,
            replayed: false
        ))
    }
}

private final class ReceiptReconciliationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
