import Foundation
import Synchronization
import Testing
@testable import second_brain_mcp

@Suite("PDF snapshot admission")
struct PDFSnapshotAdmissionTests {
    @Test("PDF content does not capture source bytes before its shared PDF permit")
    func contentSnapshotWaitsForAdmission() async throws {
        try await checkSnapshotAdmission(view: .content)
    }

    @Test("PDF metadata does not capture source bytes before its shared PDF permit")
    func metadataSnapshotWaitsForAdmission() async throws {
        try await checkSnapshotAdmission(view: .metadata)
    }

    @Test("A cancelled queued PDF read captures no bytes and releases its waiter")
    func queuedCancellationDoesNotCapture() async throws {
        let fixture = try PDFAdmissionFixture.make()
        defer { fixture.cleanup() }
        let hold = PDFSnapshotAdmissionHold()
        let blocker = Task {
            try await fixture.gate.withPermit { await hold.wait() }
        }
        await hold.waitUntilEntered()
        let read = Task {
            try await fixture.service.read(ReadFileRequest(
                format: .pdf, path: "references/0.pdf", options: .default
            ))
        }
        let queued = await waitForQueue(fixture.gate, count: 1)
        read.cancel()
        let result = await read.result
        let remaining = await fixture.gate.waitingCount
        let capturedBeforeRelease = fixture.captures.bytes
        await hold.release()
        try await blocker.value
        #expect(queued)
        guard case .failure(let error) = result else {
            Issue.record("A cancelled queued PDF read unexpectedly succeeded")
            return
        }
        #expect(error is CancellationError)
        #expect(remaining == 0)
        #expect(capturedBeforeRelease == 0)
    }

    @Test("A PDF caller queued on admission does not hold the vault read lease")
    func queuedPDFLeavesVaultAvailable() async throws {
        let fixture = try PDFAdmissionFixture.make()
        defer { fixture.cleanup() }
        let hold = PDFSnapshotAdmissionHold()
        let blocker = Task {
            try await fixture.gate.withPermit { await hold.wait() }
        }
        await hold.waitUntilEntered()
        let read = Task {
            try await fixture.service.read(ReadFileRequest(
                format: .pdf, path: "references/0.pdf", options: ReadFileOptions(view: .metadata)
            ))
        }
        let queued = await waitForQueue(fixture.gate, count: 1)
        let acquired = WriterFlag()
        let writer = Task {
            try await fixture.access.withMutation { await acquired.mark() }
        }
        let writerBeforeRelease = await acquired.markedBeforeDeadline()
        await hold.release()
        try await blocker.value
        _ = try await read.value
        try await writer.value
        #expect(queued)
        #expect(writerBeforeRelease, "Waiting for PDF admission must not block unrelated vault mutations")
    }

    @Test("A PDF binding without metadata capability rejects before capturing source bytes")
    func missingMetadataBindingDoesNotCapture() async throws {
        let fixture = try PDFAdmissionFixture.make(missingPDFMetadata: true)
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.service.read(ReadFileRequest(
                format: .pdf, path: "references/0.pdf", options: ReadFileOptions(view: .metadata)
            ))
            Issue.record("Metadata must not bypass the catalog's PDF ownership boundary")
        } catch FileRoutingError.invalidReadOptions {
            // A manually registered content-only PDF binding has no metadata capability.
        }
        #expect(fixture.captures.bytes == 0)
    }

    private func checkSnapshotAdmission(view: ReadFileView) async throws {
        let fixture = try PDFAdmissionFixture.make()
        defer { fixture.cleanup() }
        let hold = PDFSnapshotAdmissionHold()
        let blocker = Task {
            try await fixture.gate.withPermit { await hold.wait() }
        }
        await hold.waitUntilEntered()
        let reads = (0..<2).map { index in
            Task {
                try await fixture.service.read(ReadFileRequest(
                    format: .pdf, path: "references/\(index).pdf",
                    options: ReadFileOptions(view: view)
                ))
            }
        }
        let queued = await waitForQueue(fixture.gate, count: 2)
        let bytesBeforeAdmission = fixture.captures.bytes
        await hold.release()
        try await blocker.value
        var failedRead: (any Error)?
        for read in reads {
            do { _ = try await read.value } catch { failedRead = error }
        }
        if let failedRead { throw failedRead }
        #expect(queued, "Both real PDF reads must reach the held admission boundary")
        #expect(bytesBeforeAdmission == 0, "Queued PDF requests must not retain pre-admission snapshots")
        #expect(fixture.captures.bytes == 2 * fixture.pdfBytes)
    }

    private actor WriterFlag {
        private var marked = false
        func mark() { marked = true }
        func markedBeforeDeadline() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !marked, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
            return marked
        }
    }

    private func waitForQueue(_ gate: AsyncExclusiveGate, count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.waitingCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await gate.waitingCount == count
    }
}

struct PDFAdmissionFixture: Sendable {
    let parent: URL
    let vault: URL
    let gate: AsyncExclusiveGate
    let admission: PDFReadAdmission
    let coordinator: VaultAccessCoordinator
    let access: any VaultAccessCoordinating
    let capabilities: FileCapabilities
    let service: VaultFileService
    let captures: PDFCapturedBytes
    let pdfBytes: Int

    static func make(
        missingPDFMetadata: Bool = false,
        wrapAccess: @Sendable (VaultAccessCoordinator) -> any VaultAccessCoordinating = { $0 }
    ) throws -> PDFAdmissionFixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFSnapshotAdmissionTests-\(UUID().uuidString)")
        let vault = parent.appendingPathComponent("vault")
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("references"), withIntermediateDirectories: true
        )
        let pdf = try generatedSearchPDF(pages: ["Admission fixture"])
        for index in 0..<2 {
            try pdf.write(to: vault.appendingPathComponent("references/\(index).pdf"))
        }
        let gate = AsyncExclusiveGate(maximumWaiters: 4)
        let admission = PDFReadAdmission(gate: gate)
        let reader = PDFReader(admission: admission)
        let sources = ExternalFileSourceValidator(vaultPath: vault.path)
        var catalog = FileFormatCatalogFactory.build(
            imageReader: ImageReader(encoder: CoreGraphicsImageEncoder(), limits: .default),
            imageImporter: ImageImporter(
                sourceValidator: sources, encoder: CoreGraphicsImageEncoder(), limits: .default
            ),
            videoImporter: VideoImporter(sourceValidator: sources, encoder: AVFoundationVideoEncoder()),
            pdfReader: reader
        )
        if missingPDFMetadata {
            catalog = FileFormatCatalog(definitions: [
                FileFormatDefinition(format: .pdf, operations: FormatOperations(
                    create: nil,
                    read: ReadOperationBinding(
                        allowedAreas: [.references], execute: PDFFileOperations(reader: reader).read
                    ),
                    update: nil, delete: nil
                )),
            ])
        }
        let captures = PDFCapturedBytes()
        let store = VaultCRUDStore(vaultPath: vault.path, snapshotLoader: { target, limit, hidden, observer in
            let snapshot = try VaultFileInspector.snapshot(
                target, maximumBytes: limit,
                rejectHiddenDescendantsOf: hidden, didReadBytes: observer
            )
            captures.record(snapshot.data.count)
            return snapshot
        })
        let coordinator = VaultAccessCoordinator(
            lockURL: parent.appendingPathComponent("vault-access.lock")
        )
        let access = wrapAccess(coordinator)
        let service = VaultFileService(
            vaultPath: vault.path, catalog: catalog, store: store,
            mutations: VaultMutationExecutor(versioning: UnusedPDFVersioning()), access: access,
            metadataReader: FileMetadataReader(), readOnly: true
        )
        return PDFAdmissionFixture(
            parent: parent, vault: vault, gate: gate, admission: admission,
            coordinator: coordinator, access: access, capabilities: catalog.capabilities(),
            service: service, captures: captures, pdfBytes: pdf.count
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: parent) }
}

final class PDFCapturedBytes: Sendable {
    private let value = Mutex(0)
    var bytes: Int { value.withLock { $0 } }
    func record(_ count: Int) { value.withLock { $0 += count } }
}

actor PDFSnapshotAdmissionHold {
    private var entered = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct UnusedPDFVersioning: VaultVersioning {
    func prepareForMutation(changing paths: [String]?) async throws {
        Issue.record("Read-only PDF fixtures must never prepare persistence")
    }

    func recordSnapshot() async throws {
        Issue.record("Read-only PDF fixtures must never request persistence")
    }
}
