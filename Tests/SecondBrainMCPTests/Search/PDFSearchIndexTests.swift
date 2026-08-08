import Darwin
import Foundation
import SQLite3
import Testing
@testable import SecondBrainMCP

@Suite("Persistent PDF search index")
struct PDFSearchIndexTests {
    @Test("A warm index survives a new service instance and changed bytes replace old pages")
    func persistenceAndInvalidation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/book.pdf"
        let url = fixture.root.appendingPathComponent(path)
        try generatedSearchPDF(
            pages: ["durable alpha sentinel"],
            title: "Durable Book"
        ).write(to: url, options: .atomic)
        let request = try validatedRequest(
            query: "durable alpha sentinel",
            root: fixture.root.path
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )

        let firstExtractions = ExtractionCounter()
        let firstIndex = makeIndex(fixture, extractionObserver: {
            firstExtractions.increment()
        })
        let first = try await firstIndex.indexedDocuments(
            targets: [target],
            request: request
        )
        #expect(first.documentsByPath[path]?.document.sections.first?.physicalPage == 1)
        #expect(first.documentsByPath[path]?.document.sections.first?.content
            .contains("durable alpha sentinel") == true)
        #expect(firstExtractions.value == 1)
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        let generationAfterFirst = try PDFSearchIndexDatabase(url: databaseURL).generation()

        let warmExtractions = ExtractionCounter()
        let secondIndex = makeIndex(fixture, extractionObserver: {
            warmExtractions.increment()
        })
        let warm = try await secondIndex.indexedDocuments(
            targets: [target],
            request: request
        )
        #expect(warm.documentsByPath[path]?.document.sections.count == 1)
        #expect(warm.documentsByPath[path]?.revisionState
            == first.documentsByPath[path]?.revisionState)
        #expect(warmExtractions.value == 0)
        #expect(try PDFSearchIndexDatabase(url: databaseURL).generation()
            == generationAfterFirst)

        try generatedSearchPDF(
            pages: ["replacement beta sentinel"],
            title: "Durable Book"
        ).write(to: url, options: .atomic)
        let replacementRequest = try validatedRequest(
            query: "replacement beta sentinel",
            root: fixture.root.path
        )
        let changed = try await secondIndex.indexedDocuments(
            targets: [target],
            request: replacementRequest
        )
        #expect(changed.documentsByPath[path]?.document.sections.first?.content
            .contains("replacement beta sentinel") == true)
        #expect(changed.documentsByPath[path]?.revisionState
            != first.documentsByPath[path]?.revisionState)
        #expect(warmExtractions.value == 1)

        let stale = try await secondIndex.indexedDocuments(
            targets: [target],
            request: request
        )
        #expect(stale.documentsByPath[path]?.document.sections.isEmpty == true)
    }

    @Test("Title truncation is independent from complete page text extraction")
    func fieldRelativeTitleTruncation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFIndexTitleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.pdf")
        try generatedSearchPDF(
            pages: ["complete body sentinel"],
            title: "A deliberately long generated title"
        ).write(to: url)

        let extraction = try PDFIndexExtractor.extract(
            snapshotURL: url,
            path: "references/book.pdf",
            includePages: true,
            maximumMetadataBytes: 8
        )
        #expect(extraction.titleTruncated)
        #expect(extraction.status == .extracted)
        #expect(extraction.pages.count == 1)
    }

    @Test("A safe index is tombstoned when the current PDF becomes sensitive")
    func sensitiveReplacementRemovesOldPages() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/book.pdf"
        let url = fixture.root.appendingPathComponent(path)
        try generatedSearchPDF(pages: ["formerly safe searchable sentinel"]).write(
            to: url,
            options: .atomic
        )
        let request = try validatedRequest(query: "searchable sentinel", root: fixture.root.path)
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let index = makeIndex(fixture)
        let safe = try await index.indexedDocuments(targets: [target], request: request)
        #expect(safe.documentsByPath[path]?.document.sections.count == 1)

        try generatedSearchPDF(pages: [
            "-----BEGIN PRIVATE KEY-----\ncurrent unsafe revision"
        ]).write(to: url, options: .atomic)
        let rejected = try await index.indexedDocuments(targets: [target], request: request)
        #expect(rejected.sensitivePaths == Set([path]))
        #expect(rejected.documentsByPath[path] == nil)

        let database = try PDFSearchIndexDatabase(
            url: fixture.dataDirectory.searchIndexDirectoryURL
                .appendingPathComponent("pdf-pages-v1.sqlite3")
        )
        #expect(try database.record(path: path) == nil)
    }

    @Test("A warm 400-PDF search performs no extraction and one scoped candidate query")
    func warmSearchBatchesCandidateSQL() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pdf = try generatedSearchPDF(pages: ["shared warm corpus sentinel"])
        var targets: [ReadableFileTarget] = []
        for number in 0..<400 {
            let path = "references/book-\(number).pdf"
            try pdf.write(
                to: fixture.root.appendingPathComponent(path),
                options: .atomic
            )
            targets.append(try ReadableFileTarget.resolve(
                path: path,
                format: .pdf,
                vaultPath: fixture.root.path
            ))
        }
        let request = try validatedRequest(
            query: "shared warm corpus sentinel",
            root: fixture.root.path
        )
        let cold = try await makeIndex(fixture).indexedDocuments(
            targets: targets,
            request: request
        )
        #expect(cold.documentsByPath.count == 400)

        let extractions = ExtractionCounter()
        let candidateQueries = ExtractionCounter()
        let warmIndex = makeIndex(
            fixture,
            extractionObserver: { extractions.increment() },
            candidateQueryObserver: { candidateQueries.increment() }
        )
        let warm = try await warmIndex.indexedDocuments(
            targets: targets,
            request: request
        )

        #expect(warm.documentsByPath.count == 400)
        #expect(extractions.value == 0)
        #expect(candidateQueries.value == 1)
    }

    @Test("Repeated phrase terms remain ordered in indexed PDF candidates")
    func repeatedPhraseTerms() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/repeated.pdf"
        try generatedSearchPDF(pages: ["go to go home safely"]).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(
            query: "go to go home",
            root: fixture.root.path,
            strategy: .phrase
        )

        let result = try await makeIndex(fixture).indexedDocuments(
            targets: [target],
            request: request
        )

        #expect(result.documentsByPath[path]?.document.sections.count == 1)
        #expect(result.candidateLimited == false)
    }

    @Test("Smart indexed search preserves symbol-only literal queries")
    func smartLiteralFallback() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/literal.pdf"
        try generatedSearchPDF(pages: ["C++ stable marker"]).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(
            query: "++",
            root: fixture.root.path,
            strategy: .smart
        )
        #expect(request.queryTokens.isEmpty)

        let result = try await makeIndex(fixture).indexedDocuments(
            targets: [target],
            request: request
        )
        #expect(result.documentsByPath[path]?.document.sections.first?.content
            .contains("++") == true)
    }

    @Test("Fuzzy vocabulary cache is invalidated after an indexed revision changes")
    func fuzzyCacheInvalidation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/fuzzy.pdf"
        let url = fixture.root.appendingPathComponent(path)
        try generatedSearchPDF(pages: ["unrelated initial vocabulary"]).write(to: url)
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(
            query: "focsu",
            root: fixture.root.path,
            strategy: .fuzzy
        )
        let index = makeIndex(fixture)

        let initial = try await index.indexedDocuments(targets: [target], request: request)
        #expect(initial.documentsByPath[path]?.document.sections.isEmpty == true)

        try generatedSearchPDF(pages: ["focus is now indexed"]).write(
            to: url,
            options: .atomic
        )
        let changed = try await index.indexedDocuments(targets: [target], request: request)
        #expect(changed.documentsByPath[path]?.document.sections.first?.content
            .contains("focus") == true)
    }

    @Test("Fuzzy cache observes revisions published by another index actor")
    func crossActorFuzzyCacheInvalidation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/cross-actor.pdf"
        let url = fixture.root.appendingPathComponent(path)
        try generatedSearchPDF(pages: ["unrelated initial vocabulary"]).write(to: url)
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(
            query: "focsu",
            root: fixture.root.path,
            strategy: .fuzzy
        )
        let reader = makeIndex(fixture)
        let writer = makeIndex(fixture)
        let initial = try await reader.indexedDocuments(targets: [target], request: request)
        #expect(initial.documentsByPath[path]?.document.sections.isEmpty == true)

        try generatedSearchPDF(pages: ["focus arrived from another actor"]).write(
            to: url,
            options: .atomic
        )
        _ = try await writer.indexedDocuments(targets: [target], request: request)
        let refreshed = try await reader.indexedDocuments(targets: [target], request: request)

        #expect(refreshed.documentsByPath[path]?.document.sections.first?.content
            .contains("focus") == true)
    }

    @Test("Fuzzy vocabulary traversal reports its SQLite work ceiling")
    func fuzzyVocabularyWorkCeiling() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/vocabulary.pdf"
        let vocabulary = (0..<5_000).map {
            String(format: "word%04d", $0)
        }.joined(separator: " ")
        try generatedSearchPDF(pages: [vocabulary]).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(
            query: "wprd9999",
            root: fixture.root.path,
            strategy: .fuzzy
        )
        let index = makeIndex(fixture, maximumVocabularyWorkCallbacks: 1)

        let result = try await index.indexedDocuments(
            targets: [target],
            request: request
        )

        #expect(result.candidateLimited)
    }

    @Test("Candidate hydration stops at the aggregate text ceiling")
    func candidateHydrationBytes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var targets: [ReadableFileTarget] = []
        for number in 0..<3 {
            let path = "references/\(number)-bounded.pdf"
            try generatedSearchPDF(pages: [
                "needle \(number) " + String(repeating: "payload ", count: 40)
            ]).write(to: fixture.root.appendingPathComponent(path))
            targets.append(try ReadableFileTarget.resolve(
                path: path,
                format: .pdf,
                vaultPath: fixture.root.path
            ))
        }
        let request = try validatedRequest(query: "needle", root: fixture.root.path)
        let index = makeIndex(fixture, maximumCandidateTextBytes: 400)

        let result = try await index.indexedDocuments(targets: targets, request: request)
        let retainedBytes = result.documentsByPath.values.flatMap {
            $0.document.sections
        }.reduce(into: 0) { $0 += $1.content.utf8.count }

        #expect(retainedBytes <= 400)
        #expect(result.candidateLimited)
    }

    @Test("Exact and FTS candidate SQL report their database-work ceiling")
    func candidateSQLWorkCeiling() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/common-candidates.pdf"
        try generatedSearchPDF(
            pages: (0..<500).map { "common candidate page \($0)" }
        ).write(to: fixture.root.appendingPathComponent(path))
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let index = makeIndex(fixture, maximumCandidateWorkCallbacks: 0)

        for strategy in [SearchStrategy.exact, .smart] {
            let request = try validatedRequest(
                query: "common",
                root: fixture.root.path,
                strategy: strategy
            )
            let result = try await index.indexedDocuments(
                targets: [target],
                request: request
            )
            #expect(result.candidateLimited)
        }
    }

    @Test("A storage-full revision is not repeatedly re-extracted")
    func storageFullBackoff() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/quota.pdf"
        let pages = (0..<300).map { number in
            "quota page \(number) " + String(repeating: "generatedpayload ", count: 20)
        }
        try generatedSearchPDF(pages: pages).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(query: "quota", root: fixture.root.path)
        let extractions = ExtractionCounter()
        let index = makeIndex(
            fixture,
            maximumDatabaseBytes: 256 * 1_024,
            extractionObserver: { extractions.increment() }
        )

        let first = try await index.indexedDocuments(
            targets: [target],
            request: request
        )
        let second = try await index.indexedDocuments(
            targets: [target],
            request: request
        )

        #expect(first.unavailablePaths == Set([path]))
        #expect(second.unavailablePaths == Set([path]))
        #expect(extractions.value == 1)
    }

    @Test("A peer generation change releases storage-full backoff")
    func storageFullBackoffTracksGeneration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/quota-peer.pdf"
        let pages = (0..<300).map { number in
            "peer quota page \(number) "
                + String(repeating: "generatedpayload ", count: 20)
        }
        try generatedSearchPDF(pages: pages).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(query: "quota", root: fixture.root.path)
        let extractions = ExtractionCounter()
        let constrained = makeIndex(
            fixture,
            maximumDatabaseBytes: 256 * 1_024,
            extractionObserver: { extractions.increment() }
        )
        _ = try await constrained.indexedDocuments(targets: [target], request: request)
        #expect(extractions.value == 1)

        let peer = makeIndex(fixture)
        _ = try await peer.indexedDocuments(targets: [target], request: request)
        _ = try await peer.indexedDocuments(
            targets: [],
            request: request,
            authoritativeScopePrefix: "references/"
        )

        _ = try await constrained.indexedDocuments(targets: [target], request: request)
        #expect(extractions.value == 2)
    }

    @Test("A full index gates stale PDFs across sibling scopes")
    func scopedPrunePreservesSiblingBackoff() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let generated = try generatedSearchPDF(pages: (0..<300).map { number in
            "scoped quota page \(number) "
                + String(repeating: "generatedpayload ", count: 20)
        })
        var targets: [ReadableFileTarget] = []
        for directory in ["a", "b"] {
            let path = "references/\(directory)/quota.pdf"
            let url = fixture.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try generated.write(to: url)
            targets.append(try ReadableFileTarget.resolve(
                path: path,
                format: .pdf,
                vaultPath: fixture.root.path
            ))
        }
        let request = try validatedRequest(query: "quota", root: fixture.root.path)
        let extractions = ExtractionCounter()
        let index = makeIndex(
            fixture,
            maximumDatabaseBytes: 256 * 1_024,
            extractionObserver: { extractions.increment() }
        )
        _ = try await index.indexedDocuments(targets: targets, request: request)
        #expect(extractions.value == 1)

        _ = try await index.indexedDocuments(
            targets: [targets[1]],
            request: request,
            authoritativeScopePrefix: "references/b/"
        )
        _ = try await index.indexedDocuments(
            targets: [targets[0]],
            request: request
        )

        #expect(extractions.value == 1)
    }

    @Test("Corrupt derived index is rebuilt without touching vault content")
    func corruptDatabaseRecovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        #expect(Darwin.chmod(databaseURL.path, 0o600) == 0)

        let index = makeIndex(fixture)
        try await index.prepare()

        #expect(try PDFSearchIndexDatabase(url: databaseURL).generation() == 0)
    }

    @Test("Independent index actors coordinate corrupt-index recovery")
    func concurrentCorruptDatabaseRecovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        #expect(Darwin.chmod(databaseURL.path, 0o600) == 0)
        let first = makeIndex(fixture)
        let second = makeIndex(fixture)

        async let firstPreparation: Void = first.prepare()
        async let secondPreparation: Void = second.prepare()
        _ = try await (firstPreparation, secondPreparation)

        #expect(try PDFSearchIndexDatabase(url: databaseURL).generation() == 0)
    }

    @Test("A live actor reopens after a peer rebuilds the derived index")
    func liveActorReopensAfterPeerRecovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/recovery.pdf"
        try generatedSearchPDF(pages: ["peer recovery sentinel"]).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(
            query: "peer recovery sentinel",
            root: fixture.root.path
        )
        let extractions = ExtractionCounter()
        let reader = makeIndex(fixture, extractionObserver: { extractions.increment() })
        _ = try await reader.indexedDocuments(targets: [target], request: request)
        #expect(extractions.value == 1)

        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        try Data("not a sqlite database".utf8).write(to: databaseURL, options: .atomic)
        #expect(Darwin.chmod(databaseURL.path, 0o600) == 0)
        try await makeIndex(fixture).prepare()

        let recovered = try await reader.indexedDocuments(
            targets: [target],
            request: request
        )
        #expect(recovered.documentsByPath[path]?.document.sections.first?.content
            .contains("peer recovery sentinel") == true)
        // SQLite may recover the committed row from its WAL, or rebuild and
        // extract it again. Either outcome is valid; reusing the unlinked old
        // connection and losing the current result is not.
        #expect(extractions.value == 1 || extractions.value == 2)
    }

    @Test("A complete scope prunes derived text for deleted PDFs")
    func deletedPDFPruning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/deleted.pdf"
        let url = fixture.root.appendingPathComponent(path)
        try generatedSearchPDF(pages: ["deleted private sentinel"]).write(to: url)
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(query: "sentinel", root: fixture.root.path)
        let index = makeIndex(fixture)
        _ = try await index.indexedDocuments(
            targets: [target],
            request: request,
            authoritativeScopePrefix: "references/"
        )

        try FileManager.default.removeItem(at: url)
        _ = try await index.indexedDocuments(
            targets: [],
            request: request,
            authoritativeScopePrefix: "references/"
        )

        let database = try PDFSearchIndexDatabase(
            url: fixture.dataDirectory.searchIndexDirectoryURL
                .appendingPathComponent("pdf-pages-v1.sqlite3")
        )
        #expect(try database.record(path: path) == nil)
    }

    @Test("Scope pruning includes descendants beginning with the maximum scalar")
    func maximumScalarScopePruning() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = try PDFSearchIndexDatabase(
            url: fixture.dataDirectory.searchIndexDirectoryURL
                .appendingPathComponent("pdf-pages-v1.sqlite3")
        )
        let path = "references/\u{10FFFF}x.pdf"
        _ = try database.publish(
            path: path,
            revision: "generated-revision",
            quickIdentity: PDFIndexQuickIdentity(metadata: RegularFileMetadata(
                byteCount: 1,
                modificationDate: nil
            )),
            extraction: IndexedPDFExtraction(
                title: "Generated",
                titleTruncated: false,
                pageCount: 0,
                pages: [],
                status: .noExtractableText
            )
        )

        #expect(try database.pruneMissing(
            scopePrefix: "references/",
            currentPaths: []
        ) == 1)
        #expect(try database.record(path: path) == nil)
    }

    @Test("Invalidated contract rows can still be tombstoned as sensitive")
    func invalidatedSensitiveTombstone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/invalidated.pdf"
        let url = fixture.root.appendingPathComponent(path)
        try generatedSearchPDF(pages: ["safe former revision"]).write(to: url)
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(query: "revision", root: fixture.root.path)
        let index = makeIndex(fixture)
        _ = try await index.indexedDocuments(targets: [target], request: request)
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        try executeSQL(
            "UPDATE pdf_document SET sensitive_policy_version=0",
            at: databaseURL
        )
        try generatedSearchPDF(pages: [
            "-----BEGIN PRIVATE KEY-----\nnew unsafe revision"
        ]).write(to: url, options: .atomic)

        let rejected = try await index.indexedDocuments(
            targets: [target],
            request: request
        )
        #expect(rejected.sensitivePaths == Set([path]))
        #expect(try scalarSQL("SELECT COUNT(*) FROM pdf_document", at: databaseURL) == 0)
    }

    @Test("FTS payload divergence is rejected instead of silently missing hits")
    func divergentFTSPayload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/divergent.pdf"
        try generatedSearchPDF(pages: ["canonical needle"]).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let request = try validatedRequest(query: "needle", root: fixture.root.path)
        _ = try await makeIndex(fixture).indexedDocuments(
            targets: [target],
            request: request
        )
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        try executeSQL(
            "UPDATE pdf_page_fts SET normalized_terms=NULL",
            at: databaseURL
        )

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
    }

    @Test("Extended SQLite corruption codes remain rebuildable")
    func extendedCorruptionClassification() {
        let error = PDFSearchIndexDatabase.DatabaseError(
            operation: "execute",
            message: "corrupt virtual table",
            code: SQLITE_CORRUPT | (1 << 8)
        )
        #expect(error.permitsDerivedIndexRebuild)
    }

    @Test("A hardlinked SQLite sidecar is rejected and never modified")
    func hardlinkedSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.root.appendingPathComponent("marker")
        let markerBytes = Data("do not modify".utf8)
        try markerBytes.write(to: marker)
        #expect(Darwin.chmod(marker.path, 0o600) == 0)
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        #expect(Darwin.link(marker.path, databaseURL.path + "-shm") == 0)

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
        #expect(try Data(contentsOf: marker) == markerBytes)
    }

    private struct Fixture {
        let root: URL
        let dataDirectory: VaultDataDirectory
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFSearchIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references"),
            withIntermediateDirectories: true
        )
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root.path,
            supportRoot: root.appendingPathComponent("support"),
            migrateLegacyData: false
        )
        return Fixture(root: root, dataDirectory: dataDirectory)
    }

    private func makeIndex(
        _ fixture: Fixture,
        maximumCandidateTextBytes: Int = 64 * 1_024 * 1_024,
        maximumCandidateWorkCallbacks: Int = 25_000,
        maximumVocabularyWorkCallbacks: Int = 10_000,
        maximumDatabaseBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        extractionObserver: (@Sendable () -> Void)? = nil,
        candidateQueryObserver: (@Sendable () -> Void)? = nil
    ) -> PDFSearchIndex {
        PDFSearchIndex(
            databaseURL: fixture.dataDirectory.searchIndexDirectoryURL
                .appendingPathComponent("pdf-pages-v1.sqlite3"),
            vaultPath: fixture.root.path,
            admission: PDFReadAdmission(),
            writerLock: POSIXAdvisoryFileLock(
                url: fixture.dataDirectory.lockDirectoryURL
                    .appendingPathComponent("pdf-index-writer.lock")
            ),
            maximumCandidateTextBytes: maximumCandidateTextBytes,
            maximumCandidateWorkCallbacks: maximumCandidateWorkCallbacks,
            maximumDatabaseBytes: maximumDatabaseBytes,
            maximumVocabularyWorkCallbacks: maximumVocabularyWorkCallbacks,
            extractionObserver: extractionObserver,
            candidateQueryObserver: candidateQueryObserver
        )
    }

    private func validatedRequest(
        query: String,
        root: String,
        strategy: SearchStrategy = .exact
    ) throws -> SearchResourcePolicy.ValidatedRequest {
        let fileCapabilities = FileCapabilities(formats: [
            .init(format: .pdf, operations: [.read: [.references]])
        ])
        return try SearchResourcePolicy.validate(
            VaultSearchRequest(
                query: query,
                strategy: strategy,
                fields: [.content],
                formats: [.pdf],
                areas: [.references]
            ),
            capabilities: SearchCapabilities(fileCapabilities: fileCapabilities),
            vaultPath: root,
            limits: .default
        )
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test open",
                message: "could not open fixture"
            )
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test mutation",
                message: String(cString: sqlite3_errmsg(handle))
            )
        }
    }

    private func scalarSQL(_ sql: String, at url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test open",
                message: "could not open fixture"
            )
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test scalar",
                message: String(cString: sqlite3_errmsg(handle))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test scalar",
                message: "missing row"
            )
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private final class ExtractionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
