import Foundation
import Testing
@testable import second_brain_mcp

@Suite("PDF and vault lease ordering")
struct PDFVaultLeaseOrderingTests {
    @Test("Captured search, a queued writer, and a direct PDF read all complete with shared admission")
    func searchWriterAndDirectReadDoNotCycle() async throws {
        let hold = PDFSnapshotAdmissionHold()
        let once = FirstReadClaim()
        let fixture = try PDFAdmissionFixture.make { coordinator in
            HeldFirstReadAccess(base: coordinator, hold: hold, once: once)
        }
        defer { fixture.cleanup() }
        let source = SearchCorpusBuilder(
            vaultPath: fixture.vault.path, capabilities: fixture.capabilities,
            captureStore: SearchCaptureStore(
                directory: fixture.parent.appendingPathComponent("capture"),
                vaultRoot: fixture.vault
            ),
            access: fixture.access,
            customProviders: [.pdf: PDFSearchAtomProvider(
                cacheRoot: fixture.parent.appendingPathComponent("index"), admission: fixture.admission
            )]
        )
        let progress = Progress()
        let search = Task {
            do {
                let result = try await VaultSearchEngine(source: source).search(VaultSearchRequest(
                    location: .references, formats: [.pdf], query: "Admission"
                ))
                await progress.finish("search")
                return result
            } catch {
                await progress.finish("search")
                throw error
            }
        }
        await hold.waitUntilEntered()
        let writer = Task {
            do {
                try await fixture.access.withMutation { await progress.finish("writer") }
            } catch {
                await progress.finish("writer")
                throw error
            }
        }
        let writerQueued = await waitForVaultQueue(fixture.coordinator, count: 1)
        let direct = Task {
            do {
                let result = try await fixture.service.read(ReadFileRequest(
                    format: .pdf, path: "references/0.pdf", options: ReadFileOptions(view: .metadata)
                ))
                await progress.finish("read")
                return result
            } catch {
                await progress.finish("read")
                throw error
            }
        }
        let bothQueued = await waitForVaultQueue(fixture.coordinator, count: 2)
        await hold.release()
        let completed = await progress.allFinishedBeforeDeadline()
        if !completed {
            search.cancel()
            writer.cancel()
            direct.cancel()
        }
        let searchResult = await search.result
        let writerResult = await writer.result
        let directResult = await direct.result
        #expect(writerQueued && bothQueued)
        #expect(completed, "The PDF/vault wait graph must not form a cycle")
        try writerResult.get()
        #expect(try searchResult.get().results.count == 2)
        #expect(try directResult.get().readMetadata?.pageCount == 1)
        let order = await progress.order
        let writerIndex = try #require(order.firstIndex(of: "writer"))
        let readerIndex = try #require(order.firstIndex(of: "read"))
        #expect(writerIndex < readerIndex)
    }

    private func waitForVaultQueue(_ access: VaultAccessCoordinator, count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await access.waitingOperationCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await access.waitingOperationCount == count
    }

    private actor FirstReadClaim {
        private var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private struct HeldFirstReadAccess: VaultAccessCoordinating {
        let base: VaultAccessCoordinator
        let hold: PDFSnapshotAdmissionHold
        let once: FirstReadClaim

        func withRead<Result: Sendable>(
            _ operation: @escaping @Sendable () async throws -> Result
        ) async throws -> Result {
            try await base.withRead {
                if await once.claim() { await hold.wait() }
                try Task.checkCancellation()
                return try await operation()
            }
        }

        func withMutation<Result: Sendable>(
            _ operation: @escaping @Sendable () async throws -> Result
        ) async throws -> Result {
            try await base.withMutation(operation)
        }
    }

    private actor Progress {
        private(set) var order: [String] = []
        func finish(_ name: String) { order.append(name) }

        func allFinishedBeforeDeadline() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while order.count < 3, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
            return order.count == 3
        }
    }
}
