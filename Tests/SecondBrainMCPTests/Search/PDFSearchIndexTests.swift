import Darwin
import Foundation
import SQLite3
import Testing
@testable import SecondBrainMCP

@Suite("Persistent PDF search index")
struct PDFSearchIndexTests {
    @Test("Production composition indexes large PDFs under bounded query hydration")
    func productionConfigurationContract() {
        let configuration = VaultRuntime.pdfSearchIndexConfiguration

        #expect(configuration == .production)
        #expect(configuration.maximumIndexedSourceFileBytes
            == FileFormat.pdf.maximumFileBytes)
        #expect(configuration.maximumIndexedSourceFileBytes
            == 512 * 1_024 * 1_024)
        #expect(configuration.maximumHydratedTextBytesPerQuery
            == 64 * 1_024 * 1_024)
        #expect(configuration.maximumHydratedTextBytesPerQuery
            < configuration.maximumIndexedSourceFileBytes)
        #expect(configuration.maximumHydratedPagesPerQuery
            <= configuration.extraction.maximumPages)
        #expect(configuration.extraction == .production)
        #expect(configuration.extraction.maximumTextBytes == 64 * 1_024 * 1_024)
        #expect(configuration.extraction.maximumPageTextBytes == 4 * 1_024 * 1_024)
        #expect(configuration.extraction.retainedRepresentationByteLimit
            == 256 * 1_024 * 1_024)
        #expect(configuration.extraction.maximumTokensPerPage == 500_000)
        #expect(configuration.extraction.maximumTokenScalars == 64)
        #expect(configuration.extraction.maximumPrintedPageLabelBytes
            == SearchRequestLimits.maximumLocatorBytes)
    }

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
            configuration: .init(maximumMetadataBytes: 8)
        )
        #expect(extraction.titleTruncated)
        #expect(extraction.status == .extracted)
        #expect(extraction.pages.count == 1)
    }

    @Test("Streaming PDF terms exactly match the shared bounded tokenizer")
    func streamingNormalizedTerms() throws {
        let source = "HTTPServer fooBar café42 repeated repeated"
        let tokens = try SearchTokenizer.boundedTokens(
            in: source,
            maximumTokens: 100,
            maximumTokenScalars: 64
        )
        let projection = try SearchTokenizer.boundedNormalizedTerms(
            in: source,
            maximumTokens: 100,
            maximumTokenScalars: 64,
            maximumBytes: 1_024
        )

        #expect(projection.value == tokens.tokens.map(\.normalized)
            .joined(separator: " "))
        #expect(projection.truncated == tokens.truncated)
    }

    @Test("PDF index representations obey one aggregate retained-byte ceiling")
    func aggregateRepresentationCeiling() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/representation.pdf"
        let url = fixture.root.appendingPathComponent(path)
        try generatedSearchPDF(pages: [
            "first retained marker alpha beta gamma",
            "second bounded marker delta epsilon zeta",
            "third bounded marker eta theta iota",
        ]).write(to: url)
        let complete = try PDFIndexExtractor.extract(
            snapshotURL: url,
            path: path,
            includePages: true,
            configuration: .init(maximumTextBytes: 1_024 * 1_024)
        )
        let first = try #require(complete.pages.first)
        let ceiling = first.rawText.utf8.count
            + first.literalFolded.utf8.count
            + first.normalizedTerms.utf8.count
            + (first.printedPage?.utf8.count ?? 0)

        let limited = try PDFIndexExtractor.extract(
            snapshotURL: url,
            path: path,
            includePages: true,
            configuration: .init(
                maximumTextBytes: 1_024 * 1_024,
                maximumRepresentationBytes: ceiling
            )
        )
        let retainedBytes = limited.pages.reduce(into: 0) {
            $0 += $1.rawText.utf8.count
                + $1.literalFolded.utf8.count
                + $1.normalizedTerms.utf8.count
                + ($1.printedPage?.utf8.count ?? 0)
        }

        #expect(retainedBytes <= ceiling)
        #expect(limited.pages.first?.rawText.contains("first retained marker") == true)
        #expect(limited.status == .partial)
    }

    @Test("Printed PDF labels are part of the retained representation ceiling")
    func printedLabelRepresentationAccounting() {
        let label = String(
            repeating: "l",
            count: PDFIndexExtractor.Configuration.production
                .maximumPrintedPageLabelBytes
        )
        let page = IndexedPDFPage(
            physicalPage: 1,
            printedPage: label,
            kind: .body,
            lineCount: 1,
            rawText: "body",
            literalFolded: "body",
            normalizedTerms: "body"
        )

        #expect(PDFIndexExtractor.retainedRepresentationByteCount(for: page)
            == label.utf8.count + 12)
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
        let coldIndex = makeIndex(fixture)
        var cold = try await coldIndex.indexedDocuments(
            targets: targets,
            request: request
        )
        // PDFKit may report a transient cannot-open while the full test suite is
        // rendering other independent documents. Production reports that file
        // unavailable for the request and retries it on the next search; mirror
        // that bounded retry here before evaluating the warm-cache invariant.
        if cold.documentsByPath.count != targets.count {
            cold = try await coldIndex.indexedDocuments(
                targets: targets,
                request: request
            )
        }
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

    @Test("PDF candidate expansion follows the final matcher's shared edit policy")
    func fuzzyPolicyParity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "references/fuzzy-policy.pdf"
        try generatedSearchPDF(pages: ["focus abcd abcdxfgi"]).write(
            to: fixture.root.appendingPathComponent(path)
        )
        let target = try ReadableFileTarget.resolve(
            path: path,
            format: .pdf,
            vaultPath: fixture.root.path
        )
        let index = makeIndex(fixture)

        let transposition = try await index.indexedDocuments(
            targets: [target],
            request: try validatedRequest(
                query: "focsu",
                root: fixture.root.path,
                strategy: .fuzzy
            )
        )
        #expect(transposition.documentsByPath[path]?.document.sections.isEmpty == false)

        let twoLongEdits = try await index.indexedDocuments(
            targets: [target],
            request: try validatedRequest(
                query: "abcdefgh",
                root: fixture.root.path,
                strategy: .fuzzy
            )
        )
        #expect(twoLongEdits.documentsByPath[path]?.document.sections.isEmpty == false)

        let twoShortEdits = try await index.indexedDocuments(
            targets: [target],
            request: try validatedRequest(
                query: "badc",
                root: fixture.root.path,
                strategy: .fuzzy
            )
        )
        #expect(twoShortEdits.documentsByPath[path]?.document.sections.isEmpty == true)
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
        let index = makeIndex(
            fixture,
            maximumFuzzyVocabularyWorkCallbacks: 1
        )

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
        let index = makeIndex(fixture, maximumHydratedTextBytesPerQuery: 400)

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
        let index = makeIndex(fixture, maximumCandidateQueryWorkCallbacks: 0)

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
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        #expect(try databaseBundleByteCount(databaseURL) <= 256 * 1_024)
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

    @Test("A forced exhaustive diagnostic rejects divergent FTS payload")
    func forcedDiagnosticRejectsDivergentFTSPayload() async throws {
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
            _ = try PDFSearchIndexDatabase(
                url: databaseURL,
                forceExhaustiveIntegrity: true
            )
        }
    }

    @Test("Warm opens use bounded trust probes while explicit diagnostics are exhaustive")
    func warmIntegrityTrustBoundary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        let integrityChecks = ExtractionCounter()

        do {
            _ = try PDFSearchIndexDatabase(
                url: databaseURL,
                exhaustiveIntegrityObserver: { integrityChecks.increment() }
            )
        }
        #expect(integrityChecks.value == 1)
        let beforeWarmOpen = try databaseFileIdentity(databaseURL)

        do {
            let warm = try PDFSearchIndexDatabase(
                url: databaseURL,
                exhaustiveIntegrityObserver: { integrityChecks.increment() }
            )
            #expect(try warm.generation() == 0)
        }
        #expect(integrityChecks.value == 1)
        #expect(try databaseFileIdentity(databaseURL) == beforeWarmOpen)

        _ = try PDFSearchIndexDatabase(
            url: databaseURL,
            exhaustiveIntegrityObserver: { integrityChecks.increment() },
            forceExhaustiveIntegrity: true
        )
        #expect(integrityChecks.value == 2)
    }

    @Test("An unversioned nonempty database is rejected rather than adopted")
    func unversionedNonemptyDatabase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        try Data().write(to: databaseURL)
        #expect(Darwin.chmod(databaseURL.path, 0o600) == 0)
        try executeSQL("CREATE TABLE foreign_object(value TEXT)", at: databaseURL)

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
        #expect(try scalarSQL(
            "SELECT COUNT(*) FROM sqlite_schema WHERE name='index_meta'",
            at: databaseURL
        ) == 0)
    }

    @Test("A missing warm schema object triggers safe derived-cache recovery")
    func missingWarmSchemaRecovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        do { _ = try PDFSearchIndexDatabase(url: databaseURL) }
        try executeSQL("DROP TABLE index_meta", at: databaseURL)

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
        try await makeIndex(fixture).prepare()
        #expect(try scalarSQL("SELECT COUNT(*) FROM index_meta", at: databaseURL) == 1)
        #expect(try scalarSQL("PRAGMA user_version", at: databaseURL)
            == PDFSearchIndexContract.schemaVersion)
    }

    @Test("Large replace and prune stay inside the peak database bundle quota")
    func publishedBundleQuota() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        let maximumBytes: Int64 = 16 * 1_024 * 1_024
        let observedPeak = PeakByteCounter()
        let database = try PDFSearchIndexDatabase(
            url: databaseURL,
            maximumDatabaseBytes: maximumBytes,
            peakBundleByteObserver: { observedPeak.record($0) }
        )
        let pages = (1...400).map { page in
            IndexedPDFPage(
                physicalPage: page,
                printedPage: nil,
                kind: .body,
                lineCount: 1,
                rawText: "bounded publication page \(page)",
                literalFolded: "bounded publication page \(page)",
                normalizedTerms: "bounded publication page \(page)"
            )
        }
        _ = try database.publish(
            path: "references/bounded-publication.pdf",
            revision: "generated",
            quickIdentity: PDFIndexQuickIdentity(metadata: RegularFileMetadata(
                byteCount: 1,
                modificationDate: nil
            )),
            extraction: IndexedPDFExtraction(
                title: "Bounded Publication",
                titleTruncated: false,
                pageCount: pages.count,
                pages: pages,
                status: .extracted
            )
        )
        let replacement = (1...400).map { page in
            IndexedPDFPage(
                physicalPage: page,
                printedPage: nil,
                kind: .body,
                lineCount: 1,
                rawText: "replacement publication page \(page)",
                literalFolded: "replacement publication page \(page)",
                normalizedTerms: "replacement publication page \(page)"
            )
        }
        _ = try database.publish(
            path: "references/bounded-publication.pdf",
            revision: "replacement",
            quickIdentity: PDFIndexQuickIdentity(metadata: RegularFileMetadata(
                byteCount: 2,
                modificationDate: nil
            )),
            extraction: IndexedPDFExtraction(
                title: "Bounded Replacement",
                titleTruncated: false,
                pageCount: replacement.count,
                pages: replacement,
                status: .extracted
            )
        )
        let mainDatabaseBytesAfterReplace = try databaseFileByteCount(databaseURL)
        #expect(observedPeak.value > mainDatabaseBytesAfterReplace)
        #expect(observedPeak.value <= maximumBytes)
        _ = try database.publish(
            path: "references/pruned.pdf",
            revision: "pruned",
            quickIdentity: PDFIndexQuickIdentity(metadata: RegularFileMetadata(
                byteCount: 1,
                modificationDate: nil
            )),
            extraction: IndexedPDFExtraction(
                title: "Pruned",
                titleTruncated: false,
                pageCount: 1,
                pages: [replacement[0]],
                status: .extracted
            )
        )
        observedPeak.reset()
        #expect(try database.pruneMissing(
            scopePrefix: "references/",
            currentPaths: ["references/bounded-publication.pdf"]
        ) == 1)

        #expect(observedPeak.value > 0)
        #expect(observedPeak.value <= maximumBytes)
        #expect(try databaseBundleByteCount(databaseURL) <= maximumBytes)
    }

    @Test("Remove and prune retain the bounded WAL transaction envelope")
    func destructiveBundleQuotaWithRetainedReadSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        let maximumBytes: Int64 = 8 * 1_024 * 1_024
        let observedPeak = PeakByteCounter()
        let database = try PDFSearchIndexDatabase(
            url: databaseURL,
            maximumDatabaseBytes: maximumBytes,
            peakBundleByteObserver: { observedPeak.record($0) }
        )
        func extraction(_ marker: String) -> IndexedPDFExtraction {
            IndexedPDFExtraction(
                title: marker,
                titleTruncated: false,
                pageCount: 1,
                pages: [IndexedPDFPage(
                    physicalPage: 1,
                    printedPage: nil,
                    kind: .body,
                    lineCount: 1,
                    rawText: marker,
                    literalFolded: marker,
                    normalizedTerms: marker
                )],
                status: .extracted
            )
        }
        for (path, marker) in [
            ("references/removed.pdf", "removed marker"),
            ("references/pruned.pdf", "pruned marker"),
        ] {
            _ = try database.publish(
                path: path,
                revision: marker,
                quickIdentity: PDFIndexQuickIdentity(metadata: RegularFileMetadata(
                    byteCount: 1,
                    modificationDate: nil
                )),
                extraction: extraction(marker)
            )
        }

        var reader: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &reader,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let openedReader = reader else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test open",
                message: "could not retain a read snapshot"
            )
        }
        defer {
            if let reader {
                _ = sqlite3_exec(reader, "ROLLBACK", nil, nil, nil)
                sqlite3_close(reader)
            }
        }
        guard sqlite3_exec(openedReader, "BEGIN", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(
                openedReader,
                "SELECT COUNT(*) FROM pdf_document",
                nil,
                nil,
                nil
              ) == SQLITE_OK else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test snapshot",
                message: String(cString: sqlite3_errmsg(openedReader))
            )
        }

        observedPeak.reset()
        // The delete commits, but its final TRUNCATE checkpoint must report the
        // retained reader instead of silently ignoring the surviving WAL.
        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            try database.remove(path: "references/removed.pdf")
        }
        #expect(try database.record(path: "references/removed.pdf") == nil)
        #expect(observedPeak.value > 0)
        #expect(observedPeak.value <= maximumBytes)
        #expect(try databaseFileByteCount(
            URL(fileURLWithPath: databaseURL.path + "-wal")
        ) > 0)
        #expect(try databaseBundleByteCount(databaseURL)
            > databaseFileByteCount(databaseURL))
        #expect(try databaseBundleByteCount(databaseURL) <= maximumBytes)

        guard sqlite3_exec(openedReader, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test snapshot",
                message: String(cString: sqlite3_errmsg(openedReader))
            )
        }
        sqlite3_close(openedReader)
        reader = nil

        // The next destructive transaction must account for and checkpoint the
        // residual sidecars before predicting its own peak.
        #expect(try database.pruneMissing(
            scopePrefix: "references/",
            currentPaths: []
        ) == 1)
        #expect(try database.record(path: "references/pruned.pdf") == nil)
        #expect(observedPeak.value <= maximumBytes)
        #expect(try databaseBundleByteCount(databaseURL) <= maximumBytes)
    }

    @Test("Warm trust probes reject a derived cache with the wrong application identity")
    func applicationIdentityProbe() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        _ = try PDFSearchIndexDatabase(url: databaseURL)
        try executeSQL("PRAGMA application_id=0", at: databaseURL)

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
    }

    @Test("Warm trust probes reject excessive schema index fanout")
    func boundedWarmIndexEnumeration() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        _ = try PDFSearchIndexDatabase(url: databaseURL)
        let indexes = (1...33).map {
            "CREATE INDEX excessive_\($0) ON pdf_document(title)"
        }.joined(separator: ";")
        try executeSQL(indexes, at: databaseURL)

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
    }

    @Test("Warm trust probes reject oversized schema SQL before decoding it")
    func boundedWarmSchemaSQL() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        _ = try PDFSearchIndexDatabase(url: databaseURL)
        let padding = String(repeating: "x", count: 70_000)
        try executeSQL("""
          DROP TABLE pdf_page_vocab;
          DROP TABLE pdf_page_fts;
          CREATE VIRTUAL TABLE pdf_page_fts USING fts5(
            normalized_terms,
            tokenize='unicode61 remove_diacritics 2' /*\(padding)*/
          );
          CREATE VIRTUAL TABLE pdf_page_vocab USING fts5vocab(
            pdf_page_fts, 'row'
          );
        """, at: databaseURL)

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
    }

    @Test("Warm generation metadata probe rejects a second row")
    func boundedWarmGenerationRows() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.dataDirectory.searchIndexDirectoryURL
            .appendingPathComponent("pdf-pages-v1.sqlite3")
        _ = try PDFSearchIndexDatabase(url: databaseURL)
        try executeSQL("""
          ALTER TABLE index_meta RENAME TO replaced_index_meta;
          CREATE TABLE index_meta(id INTEGER, generation INTEGER);
          INSERT INTO index_meta(id,generation) VALUES(1,0),(2,0);
          DROP TABLE replaced_index_meta;
        """, at: databaseURL)

        #expect(throws: PDFSearchIndexDatabase.DatabaseError.self) {
            _ = try PDFSearchIndexDatabase(url: databaseURL)
        }
    }

    @Test("Publishing many pages prepares a constant number of SQL statements")
    func publishReusesStatements() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparations = ExtractionCounter()
        let database = try PDFSearchIndexDatabase(
            url: fixture.dataDirectory.searchIndexDirectoryURL
                .appendingPathComponent("pdf-pages-v1.sqlite3"),
            statementPreparationObserver: { preparations.increment() }
        )
        let onePage = IndexedPDFExtraction(
            title: "One Page",
            titleTruncated: false,
            pageCount: 1,
            pages: [IndexedPDFPage(
                physicalPage: 1,
                printedPage: nil,
                kind: .body,
                lineCount: 1,
                rawText: "one page",
                literalFolded: "one page",
                normalizedTerms: "one page"
            )],
            status: .extracted
        )
        let beforeOnePage = preparations.value
        _ = try database.publish(
            path: "references/one-page.pdf",
            revision: "one",
            quickIdentity: PDFIndexQuickIdentity(metadata: RegularFileMetadata(
                byteCount: 1,
                modificationDate: nil
            )),
            extraction: onePage
        )
        let onePagePreparations = preparations.value - beforeOnePage
        let pages = (1...200).map { page in
            IndexedPDFPage(
                physicalPage: page,
                printedPage: nil,
                kind: .body,
                lineCount: 1,
                rawText: "shared page \(page)",
                literalFolded: "shared page \(page)",
                normalizedTerms: "shared page \(page)"
            )
        }

        let beforeManyPages = preparations.value
        _ = try database.publish(
            path: "references/many-pages.pdf",
            revision: "generated",
            quickIdentity: PDFIndexQuickIdentity(metadata: RegularFileMetadata(
                byteCount: 1,
                modificationDate: nil
            )),
            extraction: IndexedPDFExtraction(
                title: "Many Pages",
                titleTruncated: false,
                pageCount: pages.count,
                pages: pages,
                status: .extracted
            )
        )

        #expect(preparations.value - beforeManyPages == onePagePreparations)
        #expect(try database.record(path: "references/many-pages.pdf")?
            .indexedPageCount == 200)
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
        maximumHydratedTextBytesPerQuery: Int = 64 * 1_024 * 1_024,
        maximumCandidateQueryWorkCallbacks: Int = 25_000,
        maximumFuzzyVocabularyWorkCallbacks: Int = 10_000,
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
            configuration: .init(
                maximumHydratedTextBytesPerQuery:
                    maximumHydratedTextBytesPerQuery,
                maximumCandidateQueryWorkCallbacks:
                    maximumCandidateQueryWorkCallbacks,
                maximumDatabaseBytes: maximumDatabaseBytes,
                maximumFuzzyVocabularyWorkCallbacks:
                    maximumFuzzyVocabularyWorkCallbacks
            ),
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

    private struct DatabaseFileIdentity: Equatable {
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private func databaseFileIdentity(_ url: URL) throws -> DatabaseFileIdentity {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw PDFSearchIndexDatabase.DatabaseError(
                operation: "test stat",
                message: url.path,
                code: errno
            )
        }
        return DatabaseFileIdentity(
            byteCount: metadata.st_size,
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }

    private func databaseBundleByteCount(_ url: URL) throws -> Int64 {
        try [url, URL(fileURLWithPath: url.path + "-wal"),
             URL(fileURLWithPath: url.path + "-shm")].reduce(into: 0) {
            $0 += try databaseFileByteCount($1)
        }
    }

    private func databaseFileByteCount(_ url: URL) throws -> Int64 {
        var metadata = stat()
        if Darwin.lstat(url.path, &metadata) == 0 { return metadata.st_size }
        if errno == ENOENT { return 0 }
        throw PDFSearchIndexDatabase.DatabaseError(
            operation: "test stat",
            message: url.path,
            code: errno
        )
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

private final class PeakByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int64 = 0

    var value: Int64 { lock.withLock { storage } }

    func record(_ bytes: Int64) {
        lock.withLock { storage = max(storage, bytes) }
    }

    func reset() {
        lock.withLock { storage = 0 }
    }
}
