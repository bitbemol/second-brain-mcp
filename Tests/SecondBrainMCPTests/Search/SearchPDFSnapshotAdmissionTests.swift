import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Search PDF snapshot admission")
struct SearchPDFSnapshotAdmissionTests {
    @Test
    func queuedSearchDoesNotMaterializePDFBeforeTheSharedPermit() async throws {
        let fixture = try PDFAdmissionFixture.make()
        defer { fixture.cleanup() }
        let loads = PDFCapturedBytes()
        let engine = searchEngine(fixture, admission: fixture.admission, loads: loads)
        let hold = PDFSnapshotAdmissionHold()
        let blocker = Task { try await fixture.gate.withPermit { await hold.wait() } }
        await hold.waitUntilEntered()
        let search = Task { try await engine.search(request) }
        let queued = await waitForQueue(fixture.gate)
        let beforeRelease = loads.bytes
        await hold.release()
        try await blocker.value
        let result = try await search.value
        #expect(queued)
        #expect(beforeRelease == 0, "A queued search must retain private disk entries, not PDF snapshot Data")
        #expect(loads.bytes == fixture.pdfBytes * 2)
        #expect(result.coverage.complete)
        #expect(result.results.map(\.path) == ["references/0.pdf", "references/1.pdf"])
    }

    @Test
    func queuedCancellationLoadsNoPDFAndCleansThePrivateCapture() async throws {
        let fixture = try PDFAdmissionFixture.make()
        defer { fixture.cleanup() }
        let loads = PDFCapturedBytes()
        let engine = searchEngine(fixture, admission: fixture.admission, loads: loads)
        let hold = PDFSnapshotAdmissionHold()
        let blocker = Task { try await fixture.gate.withPermit { await hold.wait() } }
        await hold.waitUntilEntered()
        let search = Task { try await engine.search(request) }
        let queued = await waitForQueue(fixture.gate)
        search.cancel()
        let result = await search.result
        let beforeRelease = loads.bytes
        let remaining = await fixture.gate.waitingCount
        let active = fixture.parent.appendingPathComponent("search-capture/active")
        let activeExists = FileManager.default.fileExists(atPath: active.path)
        await hold.release()
        try await blocker.value
        #expect(queued)
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("Canceled queued search unexpectedly succeeded")
        }
        #expect(beforeRelease == 0)
        #expect(remaining == 0)
        #expect(!activeExists)
        let next = try await engine.search(request)
        #expect(next.coverage.complete)
        #expect(next.results.count == 2)
        #expect(loads.bytes == fixture.pdfBytes * 2)
    }

    @Test
    func independentPDFProcessPermitAlsoPrecedesSnapshotMaterialization() async throws {
        let fixture = try PDFAdmissionFixture.make()
        defer { fixture.cleanup() }
        let loads = PDFCapturedBytes()
        let contention = PDFCapturedBytes()
        let lockURL = fixture.parent.appendingPathComponent("pdf-read.lock")
        let held = try await POSIXAdvisoryFileLock(url: lockURL).acquire(.exclusive)
        defer { held.release() }
        let admission = PDFReadAdmission(processLock: POSIXAdvisoryFileLock(
            url: lockURL, retryNanoseconds: 1_000_000,
            contentionObserver: { contention.record(1) }
        ))
        let engine = searchEngine(fixture, admission: admission, loads: loads)
        let search = Task { try await engine.search(request) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while contention.bytes == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let observedContention = contention.bytes > 0
        let beforeRelease = loads.bytes
        held.release()
        let result = try await search.value
        #expect(observedContention)
        #expect(beforeRelease == 0)
        #expect(result.coverage.complete)
        #expect(result.results.count == 2)
        #expect(loads.bytes == fixture.pdfBytes * 2)
    }

    private var request: VaultSearchRequest {
        VaultSearchRequest(location: .references, query: "Admission fixture")
    }

    private func searchEngine(
        _ fixture: PDFAdmissionFixture,
        admission: PDFReadAdmission,
        loads: PDFCapturedBytes
    ) -> VaultSearchEngine {
        let capture = SearchCaptureStore(
            directory: fixture.parent.appendingPathComponent("search-capture"),
            vaultRoot: fixture.vault, snapshotLoadObserver: { loads.record($0) }
        )
        let provider = PDFSearchAtomProvider(
            cacheRoot: fixture.parent.appendingPathComponent("search-pdf-cache"),
            admission: admission
        )
        return VaultSearchEngine(source: SearchCorpusBuilder(
            vaultPath: fixture.vault.path, capabilities: fixture.capabilities,
            captureStore: capture, access: fixture.access, customProviders: [.pdf: provider]
        ))
    }

    private func waitForQueue(_ gate: AsyncExclusiveGate) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await gate.waitingCount < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await gate.waitingCount == 1
    }
}
