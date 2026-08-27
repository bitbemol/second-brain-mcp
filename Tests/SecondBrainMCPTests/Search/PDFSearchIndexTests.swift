import CryptoKit
import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `PDF search atom provider` {
    @Test
    func `Produces and caches one atom per physical page`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let references = root.appendingPathComponent("references", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: references,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let data = try generatedSearchPDF(pages: [
            "First searchable page",
            "Second searchable page",
        ])
        let file = references.appendingPathComponent("book.pdf")
        try data.write(to: file)
        let target = try ReadableFileTarget.resolve(
            path: "references/book.pdf",
            format: .pdf,
            vaultPath: root.path
        )
        let provider = PDFSearchAtomProvider(
            cacheRoot: cache,
            admission: PDFReadAdmission()
        )
        let snapshot = FileSnapshot(data: data, modifiedDate: nil)
        let first = try await provider.atoms(for: target, snapshot: snapshot)
        let cached = try await provider.atoms(for: target, snapshot: snapshot)

        #expect(first.count == 2)
        #expect(first.map { $0.locator.page } == [1, 2])
        #expect(first[0].text.contains("First searchable page"))
        #expect(cached.map(\.text) == first.map(\.text))
    }


    @Test
    func `Validated cache hits do not repeat PDF page extraction`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Cached source evidence"])
        defer { fixture.remove() }
        let first = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        let source = PDFPageProbe(pageCount: 1) { _ in "Unexpected repeated extraction" }
        let cached = try await fixture.provider(opening: source).atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(cached.map(\.text) == first.map(\.text))
        #expect(source.readCount == 0)
    }

    @Test
    func `Pre-migration PDF text is re-extracted and the new generation is reusable`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Unchanged source bytes"])
        defer { fixture.remove() }
        let legacy = try fixture.writeLegacyV2Cache(text: "Old OCR evidence")
        let oldPage = try Data(contentsOf: legacy.page)
        let oldManifest = try Data(contentsOf: legacy.manifest)
        let document = PDFPageProbe(pageCount: 1) { _ in "Current OCR evidence" }
        let provider = fixture.provider(opening: document)

        let first = try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot)
        let warm = try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot)

        #expect(first.map(\.text) == ["Current OCR evidence"])
        #expect(first.map { $0.locator.page } == [1])
        #expect(warm.map(\.text) == first.map(\.text))
        #expect(document.readCount == 1)
        #expect(try Data(contentsOf: legacy.page) == oldPage)
        #expect(try Data(contentsOf: legacy.manifest) == oldManifest)
    }

    @Test
    func `A full pre-migration cache still permits fresh extraction without eviction`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Unchanged source bytes"])
        defer { fixture.remove() }
        let legacy = try fixture.writeLegacyV2Cache(text: "Old OCR evidence")
        let oldPage = try Data(contentsOf: legacy.page)
        let oldManifest = try Data(contentsOf: legacy.manifest)
        let occupied = fixture.cache.appendingPathComponent("legacy-quota-bytes")
        #expect(FileManager.default.createFile(atPath: occupied.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: occupied)
        try handle.truncate(atOffset: UInt64(64 * 1_024 * 1_024 - oldPage.count - oldManifest.count))
        try handle.close()
        let document = PDFPageProbe(pageCount: 1) { _ in "Fresh uncached OCR evidence" }
        let provider = fixture.provider(opening: document)

        for _ in 0..<2 {
            let atoms = try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot)
            #expect(atoms.map(\.text) == ["Fresh uncached OCR evidence"])
        }

        #expect(document.readCount == 2)
        let pages = try fixture.cacheFiles(withExtension: "txt")
            .map { $0.resolvingSymlinksInPath().path }
        let manifests = try fixture.cacheFiles(withExtension: "json")
            .map { $0.resolvingSymlinksInPath().path }
        #expect(pages == [legacy.page.resolvingSymlinksInPath().path])
        #expect(manifests == [legacy.manifest.resolvingSymlinksInPath().path])
        #expect(try Data(contentsOf: legacy.page) == oldPage)
        #expect(try Data(contentsOf: legacy.manifest) == oldManifest)
        #expect(FileManager.default.fileExists(atPath: occupied.path))
    }

    @Test
    func `Cache write failure does not hide valid PDF content`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Searchable despite unavailable cache"])
        defer { fixture.remove() }
        try Data("not a directory".utf8).write(to: fixture.cache)
        let atoms = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(atoms.count == 1)
        #expect(atoms.first?.text.contains("Searchable despite unavailable cache") == true)
    }

    @Test
    func `Changed cached page bytes cannot replace source content`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Original source evidence"])
        defer { fixture.remove() }
        let original = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        let page = try #require(fixture.cacheFiles(withExtension: "txt").first)
        try Data("Injected false cache evidence".utf8).write(to: page, options: .atomic)

        let reread = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(reread.map(\.text) == original.map(\.text))
    }

    @Test
    func `Oversized cached page is rejected before it becomes search content`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Small source evidence"])
        defer { fixture.remove() }
        let original = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        let page = try #require(fixture.cacheFiles(withExtension: "txt").first)
        try Data(repeating: 0x78, count: 2 * 1_024 * 1_024 + 1)
            .write(to: page, options: .atomic)

        let reread = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(reread.count == original.count)
        #expect(reread.first?.text.utf8.count == original.first?.text.utf8.count)
        #expect(reread.first?.text.prefix(40) == original.first?.text.prefix(40))
    }

    @Test
    func `Corrupt cache page count cannot make a nonempty PDF disappear`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Still present in source"])
        defer { fixture.remove() }
        let original = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        let manifest = try #require(fixture.cacheFiles(withExtension: "json").first)
        var fields = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as? [String: Any]
        )
        fields["pageCount"] = 0
        try JSONSerialization.data(withJSONObject: fields)
            .write(to: manifest, options: .atomic)

        let reread = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(reread.map(\.text) == original.map(\.text))
    }

    @Test
    func `Publishing a new revision never changes an existing cache generation`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Original revision evidence"])
        defer { fixture.remove() }
        let original = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        let firstPage = try #require(fixture.cacheFiles(withExtension: "txt").first)
        let firstBytes = try Data(contentsOf: firstPage)
        let changedData = try generatedSearchPDF(pages: ["Replacement revision evidence"])
        let changed = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: FileSnapshot(data: changedData, modifiedDate: nil)
        )
        #expect(changed.first?.text.contains("Replacement revision evidence") == true)
        #expect(try Data(contentsOf: firstPage) == firstBytes)

        let restored = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(restored.map(\.text) == original.map(\.text))
    }


    @Test
    func `Full cache byte quota keeps repeated revisions searchable without publication`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Searchable with full cache"])
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cache,
            withIntermediateDirectories: true
        )
        let occupied = fixture.cache.appendingPathComponent("existing-cache-bytes")
        #expect(FileManager.default.createFile(atPath: occupied.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: occupied)
        try handle.truncate(atOffset: 64 * 1_024 * 1_024)
        try handle.close()

        for index in 0..<3 {
            let data = try generatedSearchPDF(pages: ["Uncached revision \(index)"])
            let atoms = try await fixture.provider.atoms(
                for: fixture.target,
                snapshot: FileSnapshot(data: data, modifiedDate: nil)
            )
            #expect(atoms.first?.text.contains("Uncached revision \(index)") == true)
        }
        #expect(try fixture.cacheFiles(withExtension: "json").isEmpty)
        #expect(try fixture.cacheFiles(withExtension: "txt").isEmpty)
    }

    @Test
    func `Full cache entry quota keeps valid content searchable without publication`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Searchable with full cache entries"])
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cache,
            withIntermediateDirectories: true
        )
        for index in 0..<1_024 {
            #expect(FileManager.default.createFile(
                atPath: fixture.cache.appendingPathComponent("existing-\(index)").path,
                contents: Data()
            ))
        }
        let atoms = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(atoms.first?.text.contains("Searchable with full cache entries") == true)
        #expect(try fixture.cacheFiles(withExtension: "json").isEmpty)
    }

    @Test
    func `A symbolic link cache page is never followed`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Trusted source text"])
        defer { fixture.remove() }
        let original = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        let page = try #require(fixture.cacheFiles(withExtension: "txt").first)
        let external = fixture.root.appendingPathComponent("not-cache-content.txt")
        try Data("Unrelated external text".utf8).write(to: external)
        try FileManager.default.removeItem(at: page)
        try FileManager.default.createSymbolicLink(
            at: page,
            withDestinationURL: external
        )

        let reread = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(reread.map(\.text) == original.map(\.text))
        #expect(try Data(contentsOf: external) == Data("Unrelated external text".utf8))
    }

    @Test
    func `Cancellation is preserved when derived cache exists`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Cached source evidence"])
        defer { fixture.remove() }
        _ = try await fixture.provider.atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.provider.atoms(
                for: fixture.target,
                snapshot: fixture.snapshot
            )
        }
        do {
            _ = try await operation.value
            Issue.record("A canceled PDF search unexpectedly succeeded")
        } catch is CancellationError {
            // Cancellation must never be turned into a cache miss or success.
        }
    }

}

/// Tests observe cache artifacts without depending on their hashed directory names.
private struct PDFCacheFixture: Sendable {
    let root: URL
    let cache: URL
    let target: ReadableFileTarget
    let snapshot: FileSnapshot

    init(pages: [String]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let references = root.appendingPathComponent("references", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: references,
            withIntermediateDirectories: true
        )
        let data = try generatedSearchPDF(pages: pages)
        try data.write(to: references.appendingPathComponent("book.pdf"))
        target = try ReadableFileTarget.resolve(
            path: "references/book.pdf",
            format: .pdf,
            vaultPath: root.path
        )
        snapshot = FileSnapshot(data: data, modifiedDate: nil)
    }

    var provider: PDFSearchAtomProvider {
        PDFSearchAtomProvider(cacheRoot: cache, admission: PDFReadAdmission())
    }

    func cacheFiles(withExtension fileExtension: String) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: cache,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.path < $1.path }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}


@Suite
struct `PDF search extraction limits` {
    @Test
    func `A complete page at the existing two MiB boundary is preserved`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Fixture document"])
        defer { fixture.remove() }
        let text = String(repeating: "x", count: 2 * 1_024 * 1_024)
        let document = PDFPageProbe(pageCount: 1) { _ in text }
        let atoms = try await fixture.provider(opening: document).atoms(
            for: fixture.target,
            snapshot: fixture.snapshot
        )
        #expect(atoms.count == 1)
        #expect(atoms.first?.text.utf8.count == text.utf8.count)
    }

    @Test
    func `An oversized page fails instead of returning silently truncated text`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Fixture document"])
        defer { fixture.remove() }
        let text = String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)
        let document = PDFPageProbe(pageCount: 1) { _ in text }
        var rejected = false
        do {
            _ = try await fixture.provider(opening: document).atoms(
                for: fixture.target,
                snapshot: fixture.snapshot
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    @Test
    func `Aggregate extraction stops at the existing sixty four MiB budget`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Fixture document"])
        defer { fixture.remove() }
        let text = String(repeating: "x", count: 2 * 1_024 * 1_024)
        let document = PDFPageProbe(pageCount: 34) { _ in text }
        var rejected = false
        do {
            _ = try await fixture.provider(opening: document).atoms(
                for: fixture.target,
                snapshot: fixture.snapshot
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(document.readCount == 33)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    @Test
    func `A missing final page rejects all provisional document content`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Fixture document"])
        defer { fixture.remove() }
        let document = PDFPageProbe(pageCount: 2) { index in
            index == 0 ? "Early page must not become a partial successful PDF" : nil
        }
        var rejected = false
        do {
            _ = try await fixture.provider(opening: document).atoms(
                for: fixture.target,
                snapshot: fixture.snapshot
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(document.readCount == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    @Test
    func `Excessive page count is rejected before extracting any page`() async throws {
        let fixture = try PDFCacheFixture(pages: ["Fixture document"])
        defer { fixture.remove() }
        let document = PDFPageProbe(pageCount: SearchRequestLimits.maximumAtoms + 1) {
            _ in ""
        }
        var rejected = false
        do {
            _ = try await fixture.provider(opening: document).atoms(
                for: fixture.target,
                snapshot: fixture.snapshot
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(document.readCount == 0)
    }
}

/// Immutable source description with a lock-protected synchronous observation counter.
private final class PDFPageProbe: PDFSearchTextDocument, @unchecked Sendable {
    let pageCount: Int
    private let lock = NSLock()
    private var reads = 0
    private let pageText: @Sendable (Int) throws -> String?

    init(pageCount: Int, pageText: @escaping @Sendable (Int) throws -> String?) {
        self.pageCount = pageCount
        self.pageText = pageText
    }

    var readCount: Int { lock.withLock { reads } }

    func text(at index: Int) throws -> String? {
        lock.withLock { reads += 1 }
        return try pageText(index)
    }
}

private extension PDFCacheFixture {
    /// Fixed historical on-disk fixture, independent of the current cache writer/version.
    func writeLegacyV2Cache(text: String) throws -> (page: URL, manifest: URL) {
        let pathDigest = SHA256.hash(data: Data(target.relativePath.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = cache.appendingPathComponent("pdf-pages-v2", isDirectory: true)
            .appendingPathComponent("\(pathDigest)-\(snapshot.revision.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("page-00001.txt")
        let manifest = directory.appendingPathComponent("manifest.json")
        let bytes = Data(text.utf8)
        let pageDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: page)
        let fields: [String: Any] = [
            "version": 2,
            "revision": snapshot.revision.rawValue,
            "pageCount": 1,
            "byteCount": bytes.count,
            "pages": [["byteCount": bytes.count, "digest": pageDigest]],
        ]
        try JSONSerialization.data(withJSONObject: fields).write(to: manifest)
        return (page, manifest)
    }

    func provider(opening document: PDFPageProbe) -> PDFSearchAtomProvider {
        PDFSearchAtomProvider(
            cacheRoot: cache,
            admission: PDFReadAdmission(),
            openDocument: { _ in document }
        )
    }
}
