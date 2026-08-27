import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Link query attempted resource accounting")
struct LinkQueryResourceAccountingTests {
    @Test("Changed-during-read sources cannot bypass the aggregate read-work budget")
    func changedSourcesConsumeAttemptedByteBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkQueryResourceAccounting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceBytes = FileFormat.markdown.maximumFileBytes
        let count = LinkQueryExecutionLimits.maximumSourceBytes / sourceBytes + 2
        let document = Data(repeating: 0x20, count: sourceBytes)
        for index in 0..<count {
            try document.write(to: root.appendingPathComponent(
                String(format: "notes/unstable-%03d.md", index)
            ))
        }
        try Data("# Target".utf8).write(to: root.appendingPathComponent("notes/z-target.md"))

        let probe = ReadWorkProbe()
        let engine = engine(root: root, probe: probe)

        do {
            _ = try await engine.query(LinkQueryRequest(direction: .backlinks, target: "z-target"))
            Issue.record("Expected the whole-query work budget to fail, not successful partial coverage")
        } catch LinkQueryError.workBudgetExceeded {
            // Budget exhaustion must not be downgraded to an isolated-file omission.
        } catch {
            Issue.record("Unexpected query failure: \(error)")
        }
        #expect(probe.bytes <= LinkQueryExecutionLimits.maximumSourceBytes)
        #expect(probe.reads < count)
    }

    @Test("Many tiny failed sources preserve healthy backlinks within actual byte work")
    func tinyFailedSourcesDoNotReserveFullFileLimits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkQuerySmallFailures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 {
            try Data("x".utf8).write(to: root.appendingPathComponent(
                String(format: "notes/unstable-%03d.md", index)
            ))
        }
        try Data("# Target".utf8).write(to: root.appendingPathComponent("notes/z-target.md"))
        try Data("[[z-target]]".utf8).write(to: root.appendingPathComponent("notes/healthy.md"))
        let probe = ReadWorkProbe()
        let response = try await engine(root: root, probe: probe).query(
            LinkQueryRequest(direction: .backlinks, target: "z-target")
        )
        #expect(response.results.compactMap(\.sourcePath) == ["notes/healthy.md"])
        #expect(!response.coverage.complete)
        #expect(response.coverage.failedFiles == 40)
        #expect(probe.bytes < 1_000)
    }

    @Test("An oversized file remains isolated near the aggregate byte ceiling")
    func oversizedSourceDoesNotConsumeRemainingAggregateBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkQueryOversizedIsolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileBytes = FileFormat.markdown.maximumFileBytes
        let document = Data(repeating: 0x20, count: fileBytes)
        let count = LinkQueryExecutionLimits.maximumSourceBytes / fileBytes
        for index in 0..<count {
            try document.write(to: root.appendingPathComponent(
                String(format: "notes/a-%03d.md", index)
            ))
        }
        let oversized = root.appendingPathComponent("notes/b-oversized.md")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(fileBytes * 2))
        try handle.close()
        try Data("[[z-target]]".utf8).write(to: root.appendingPathComponent("notes/c-healthy.md"))
        try Data("# Target".utf8).write(to: root.appendingPathComponent("notes/z-target.md"))

        let probe = ReadWorkProbe()
        let response = try await engine(root: root, probe: probe).query(
            LinkQueryRequest(direction: .backlinks, target: "z-target")
        )
        #expect(response.results.compactMap(\.sourcePath) == ["notes/c-healthy.md"])
        #expect(!response.coverage.complete)
        #expect(response.coverage.failedFiles == 1)
        #expect(response.coverage.samples == [
            .init(path: "notes/b-oversized.md", reason: .fileLimit)
        ])
        #expect(probe.bytes <= LinkQueryExecutionLimits.maximumSourceBytes)
        #expect(probe.reads == count + 2, "The oversized source must fail before reading content")
    }

    @Test("Read work survives a real final descriptor stability failure")
    func descriptorFailureStillReportsActualReadBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkReadAccounting-\(UUID().uuidString).md")
        let bytes = Data("bounded immutable snapshot".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = ReadWorkProbe()
        do {
            _ = try BoundedFileReader.snapshot(
                fromCanonical: url, maximumBytes: bytes.count, path: "notes/source.md",
                didReadBytes: { count in
                    probe.record(count)
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path
                    )
                }
            )
            Issue.record("Expected a real final descriptor fingerprint failure")
        } catch BoundedFileReader.ReadError.changedDuringRead {
            // The actual read remains accounted even though no snapshot is returned.
        }
        #expect(probe.bytes == bytes.count)
    }

    private func engine(root: URL, probe: ReadWorkProbe) -> VaultLinkQueryEngine {
        let store = VaultCRUDStore(vaultPath: root.path, snapshotLoader: {
            target, maximum, protectedRoot, didReadBytes in
            // Exercise the real bounded descriptor read before simulating its final identity failure.
            let snapshot = try VaultFileInspector.snapshot(
                target, maximumBytes: maximum, rejectHiddenDescendantsOf: protectedRoot,
                didReadBytes: didReadBytes
            )
            probe.record(snapshot.data.count)
            if target.relativePath.hasPrefix("notes/unstable-") {
                throw BoundedFileReader.ReadError.changedDuringRead
            }
            return snapshot
        })
        return VaultLinkQueryEngine(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]])
            ]),
            store: store,
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
        )
    }

    private final class ReadWorkProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var measuredBytes = 0
        private var measuredReads = 0

        var bytes: Int {
            lock.lock()
            defer { lock.unlock() }
            return measuredBytes
        }

        var reads: Int {
            lock.lock()
            defer { lock.unlock() }
            return measuredReads
        }

        func record(_ bytes: Int) {
            lock.lock()
            defer { lock.unlock() }
            measuredBytes += bytes
            measuredReads += 1
        }
    }
}
