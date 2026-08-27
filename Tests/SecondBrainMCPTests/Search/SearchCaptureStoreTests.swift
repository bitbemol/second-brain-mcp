import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Search capture storage")
struct SearchCaptureStoreTests {
    @Test
    func capturedBytesRemainImmutableAndSessionClosesAfterCleanup() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let target = try fixture.write("original")
        let retained = try await fixture.store().withCapture { session in
            let entry = try await session.capture(target)
            try Data("replaced".utf8).write(to: target.url)
            let snapshot = try await session.snapshot(entry)
            #expect(String(decoding: snapshot.data, as: UTF8.self) == "original")
            #expect(snapshot.revision == entry.revision)
            return (session, entry)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("active").path))
        await #expect(throws: SearchCaptureStorageError.self) {
            _ = try await retained.0.snapshot(retained.1)
        }
    }

    @Test
    func exactByteLimitSucceedsAndNextSourceFailsBeforeRead() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let target = try fixture.write("12345")
        let limits = SearchCaptureLimits(maximumBytes: 5)
        let opens = CaptureOpenCounter()
        let store = fixture.store(limits: limits, observer: { _ in opens.increment() })
        try await store.withCapture { session in
            let entry = try await session.capture(target)
            let snapshot = try await session.snapshot(entry)
            #expect(snapshot.data.count == 5)
            await #expect(throws: VaultSearchRequestError.self) {
                _ = try await session.capture(target)
            }
        }
        #expect(opens.value == 1)
    }

    @Test
    func zeroByteSourcesRemainReadableAtTheExactAggregateByteLimit() async throws {
        for byteLimit in [0, 5] {
            let fixture = try CaptureFixture()
            defer { fixture.remove() }
            let full = try fixture.write("12345")
            let empty = try ReadableFileTarget.resolve(
                path: "notes/empty.md", format: .markdown, vaultPath: fixture.vault.path
            )
            try Data().write(to: empty.url)
            let opens = CaptureOpenCounter()
            let store = fixture.store(limits: SearchCaptureLimits(maximumBytes: byteLimit),
                                      observer: { _ in opens.increment() })
            try await store.withCapture { session in
                if byteLimit > 0 { _ = try await session.capture(full) }
                let entry = try await session.capture(empty)
                #expect(entry.byteCount == 0)
                let snapshot = try await session.snapshot(entry)
                #expect(snapshot.data.isEmpty)
                #expect(snapshot.revision == FileSnapshot(data: Data(), modifiedDate: nil).revision)
                await #expect(throws: VaultSearchRequestError.self) {
                    _ = try await session.capture(full)
                }
            }
            #expect(opens.value == (byteLimit == 0 ? 1 : 2))
        }
    }

    @Test
    func failedSourceAttemptsConsumeFileAndManifestBudgets() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let missing = try ReadableFileTarget.resolve(
            path: "notes/missing.md", format: .markdown, vaultPath: fixture.vault.path
        )
        let store = fixture.store(limits: SearchCaptureLimits(maximumFiles: 2))
        try await store.withCapture { session in
            for _ in 0..<2 {
                await #expect(throws: BoundedFileReader.ReadError.self) {
                    _ = try await session.capture(missing)
                }
            }
            await #expect(throws: VaultSearchRequestError.self) {
                _ = try await session.capture(missing)
            }
        }
        let tooSmall = fixture.store(limits: SearchCaptureLimits(maximumManifestBytes: 1))
        await #expect(throws: VaultSearchRequestError.self) {
            try await tooSmall.withCapture { session in
                _ = try await session.capture(missing)
            }
        }
    }

    @Test
    func changedSourceBytesAreNotRefundedAfterDiscard() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let target = try fixture.write("abc")
        let mutations = CaptureOpenCounter()
        let store = fixture.store(limits: SearchCaptureLimits(maximumBytes: 5), observer: { target in
            if mutations.incrementAndGet() == 1 {
                try? Data("xyz".utf8).write(to: target.url)
            }
        })
        try await store.withCapture { session in
            await #expect(throws: BoundedFileReader.ReadError.self) {
                _ = try await session.capture(target)
            }
            await #expect(throws: VaultSearchRequestError.self) {
                _ = try await session.capture(target)
            }
        }
        #expect(mutations.value == 1)
    }

    @Test
    func privateCorruptionIsFatalRatherThanSourceCoverage() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let target = try fixture.write("original")
        try await fixture.store().withCapture { session in
            let entry = try await session.capture(target)
            let spool = fixture.directory.appendingPathComponent("active/00000000.capture")
            try Data("tampered".utf8).write(to: spool)
            await #expect(throws: SearchCaptureStorageError.self) {
                _ = try await session.snapshot(entry)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("active").path))
    }

    @Test
    func abandonedOwnedCaptureIsRemovedButSymlinksAreRejected() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let active = fixture.directory.appendingPathComponent("active")
        try FileManager.default.createDirectory(
            at: active, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try Data("abandoned".utf8).write(to: active.appendingPathComponent("00000000.capture"))
        try await fixture.store().withCapture { _ in
            #expect(!FileManager.default.fileExists(atPath: active.appendingPathComponent("00000000.capture").path))
        }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("keep")
        try Data("safe".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: outside)
        await #expect(throws: SearchCaptureStorageError.self) {
            try await fixture.store().withCapture { _ in Issue.record("Unsafe capture admitted") }
        }
        #expect(try Data(contentsOf: sentinel) == Data("safe".utf8))
    }

    @Test
    func independentStoresCannotCleanLiveCaptureAndQueuedCancellationReleasesAdmission() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let target = try fixture.write("live capture")
        let firstStore = fixture.store()
        let contention = CaptureOpenCounter()
        let secondStore = SearchCaptureStore(
            directory: fixture.directory, vaultRoot: fixture.vault,
            processLock: POSIXAdvisoryFileLock(
                url: fixture.directory.appendingPathExtension("lock"),
                retryNanoseconds: 1_000_000,
                contentionObserver: { contention.increment() }
            )
        )
        let (entered, announce) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await firstStore.withCapture { session in
                _ = try await session.capture(target)
                announce.yield(())
                for await _ in release { break }
            }
        }
        defer { resume.yield(()); resume.finish(); first.cancel() }
        var events = entered.makeAsyncIterator()
        _ = await events.next()
        let second = Task {
            try await secondStore.withCapture { _ in Issue.record("Overlapping captures admitted") }
        }
        defer { second.cancel() }
        while contention.value == 0 { await Task.yield() }
        let live = fixture.directory.appendingPathComponent("active/00000000.capture")
        let liveBytes = try Data(contentsOf: live)
        #expect(liveBytes == Data("live capture".utf8))
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(FileManager.default.fileExists(atPath: live.path))
        resume.yield(())
        try await first.value
        try await secondStore.withCapture { session in
            _ = try await session.capture(target)
        }
    }

    @Test
    func cancellationDuringCaptureOrProcessingCleansAndReleasesAdmission() async throws {
        for duringCapture in [true, false] {
            let fixture = try CaptureFixture()
            defer { fixture.remove() }
            let target = try fixture.write("private captured bytes")
            let store = fixture.store(observer: { _ in
                if duringCapture { withUnsafeCurrentTask { $0?.cancel() } }
            })
            let canceled = Task {
                try await store.withCapture { session in
                    _ = try await session.capture(target)
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
            }
            await #expect(throws: CancellationError.self) { try await canceled.value }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("active").path))
            try await fixture.store().withCapture { session in
                _ = try await session.capture(target)
            }
        }
    }

    @Test
    func malformedAbandonedEntriesFailWithoutDeletingAnyEntry() async throws {
        for kind in ["hardlink", "unknown-name", "oversized"] {
            let fixture = try CaptureFixture()
            defer { fixture.remove() }
            let active = fixture.directory.appendingPathComponent("active")
            try FileManager.default.createDirectory(
                at: active, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let valid = active.appendingPathComponent("00000000.capture")
            try Data("preserve".utf8).write(to: valid)
            let suspect = active.appendingPathComponent(
                kind == "unknown-name" ? "unexpected" : "00000001.capture"
            )
            let outside = fixture.root.appendingPathComponent("outside-sentinel")
            try Data("outside-safe".utf8).write(to: outside)
            if kind == "hardlink" {
                try FileManager.default.linkItem(at: outside, to: suspect)
            } else {
                try Data().write(to: suspect)
                if kind == "oversized" {
                    let handle = try FileHandle(forWritingTo: suspect)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 256 * 1_024 * 1_024 + 1)
                }
            }
            await #expect(throws: SearchCaptureStorageError.self) {
                try await fixture.store().withCapture { _ in Issue.record("Malformed capture admitted") }
            }
            let validBytes = try Data(contentsOf: valid)
            let outsideBytes = try Data(contentsOf: outside)
            #expect(validBytes == Data("preserve".utf8))
            #expect(outsideBytes == Data("outside-safe".utf8))
            #expect(FileManager.default.fileExists(atPath: suspect.path))
        }
    }

    @Test
    func processingFailureCleansCaptureAndReleasesAdmission() async throws {
        let fixture = try CaptureFixture()
        defer { fixture.remove() }
        let target = try fixture.write("safe")
        let store = fixture.store()
        await #expect(throws: CaptureFixtureError.self) {
            try await store.withCapture { session in
                _ = try await session.capture(target)
                throw CaptureFixtureError.expected
            }
        }
        try await store.withCapture { session in
            _ = try await session.capture(target)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("active").path))
    }
}

private enum CaptureFixtureError: Error { case expected }

private struct CaptureFixture: Sendable {
    let root: URL
    let vault: URL
    let directory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchCaptureStoreTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        vault = root.appendingPathComponent("vault")
        directory = root.appendingPathComponent("derived/captures")
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func write(_ text: String) throws -> ReadableFileTarget {
        let target = try ReadableFileTarget.resolve(
            path: "notes/source.md", format: .markdown, vaultPath: vault.path
        )
        try Data(text.utf8).write(to: target.url)
        return target
    }

    func store(
        limits: SearchCaptureLimits = .default,
        observer: (@Sendable (ReadableFileTarget) -> Void)? = nil
    ) -> SearchCaptureStore {
        SearchCaptureStore(directory: directory, vaultRoot: vault, captureObserver: observer, limits: limits)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class CaptureOpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func incrementAndGet() -> Int { lock.withLock { count += 1; return count } }
}
