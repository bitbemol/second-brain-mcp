import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Vault search engine")
struct VaultSearchEngineTests {
    private final class SemanticEmbeddingStub: SearchSemanticEmbedding,
        @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0

        func embedding(
            for text: String,
            retention: SearchSemanticEmbeddingRetention
        ) -> [Double]? {
            lock.withLock { callCount += 1 }
            if text.contains("ordered collection") {
                return [1, 0]
            }
            if text.contains("midpoint of a sorted array") {
                return [4, 3]
            }
            return [0, 1]
        }

        var calls: Int { lock.withLock { callCount } }
    }

    private func searchCapabilities() -> SearchCapabilities {
        var formats: [FileCapabilities.Format] = FileFormat.allCases
            .filter(\.isTextual)
            .map { format in
                .init(format: format, operations: [.read: [.notes]])
            }
        formats.append(.init(format: .pdf, operations: [.read: [.references]]))
        return SearchCapabilities(fileCapabilities: FileCapabilities(formats: formats))
    }

    private func makeEngine(
        root: String,
        limits: SearchResourceLimits = .default,
        pdfIndexConfiguration: PDFSearchIndex.Configuration = .production,
        admissionGate: AsyncExclusiveGate? = nil,
        processSearchLock: POSIXAdvisoryFileLock? = nil,
        semanticEmbedding: (any SearchSemanticEmbedding)? =
            NaturalLanguageSearchSemanticEmbedding.shared
    ) throws -> VaultSearchEngine {
        let supportRoot = URL(fileURLWithPath: root)
            .appendingPathComponent(".test-support", isDirectory: true)
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root,
            supportRoot: supportRoot,
            migrateLegacyData: false
        )
        let pdfAdmission = PDFReadAdmission()
        let pdfIndex = PDFSearchIndex(
            databaseURL: dataDirectory.searchIndexDirectoryURL
                .appendingPathComponent("pdf-pages-v1.sqlite3"),
            vaultPath: root,
            admission: pdfAdmission,
            writerLock: POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("pdf-index-writer.lock")
            ),
            configuration: pdfIndexConfiguration
        )
        return VaultSearchEngine(
            vaultPath: root,
            capabilities: searchCapabilities(),
            store: VaultCRUDStore(vaultPath: root),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: dataDirectory.lockDirectoryURL
            ),
            pdfIndex: pdfIndex,
            limits: limits,
            admissionGate: admissionGate,
            processSearchLock: processSearchLock,
            semanticEmbedding: semanticEmbedding
        )
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory()
            + "VaultSearchEngineTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ text: String, to relativePath: String, root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func write(_ data: Data, to relativePath: String, root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    @Test("Title, heading, and body weights produce deterministic breadth")
    func fieldRanking() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("---\ntitle: Concurrency\n---\nA guide.", to: "notes/z-title.md", root: root)
        try write("# Concurrency\nA section.", to: "notes/a-heading.md", root: root)
        try write("# Other\nBody mentions concurrency.", to: "notes/b-body.md", root: root)

        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(query: "concurrency", strategy: .exact)
        )
        #expect(response.results.map(\.path) == [
            "notes/a-heading.md", "notes/z-title.md", "notes/b-body.md",
        ])
        #expect(response.results.count == 3)
        #expect(response.results.allSatisfy { $0.path.hasPrefix("notes/") })
    }

    @Test("Smart and fuzzy search recover misspelled multi-word queries")
    func typoSearch() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Git Safety\nConcurrent agents coordinate the Git index lock.",
            to: "notes/work/git-safety.md",
            root: root
        )
        try write("# Cooking\nTomato pasta.", to: "notes/cooking.md", root: root)
        let engine = try makeEngine(root: root)

        for strategy in [SearchStrategy.smart, .fuzzy] {
            let response = try await engine.search(VaultSearchRequest(
                query: "concurent git lok",
                strategy: strategy
            ))
            #expect(response.results.first?.path == "notes/work/git-safety.md")
        }

        try write("# Focus\nswimlane focus", to: "notes/work/focus.md", root: root)
        for strategy in [SearchStrategy.smart, .fuzzy] {
            let response = try await engine.search(VaultSearchRequest(
                query: "swimlane focsu",
                strategy: strategy
            ))
            #expect(response.results.first?.path == "notes/work/focus.md")
        }
    }

    @Test("Smart uses local semantic evidence only after literal strategies miss")
    func semanticParaphraseFallback() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            """
            # Binary search
            Compare a target with the midpoint of a sorted array, then discard
            one side after each comparison.
            """,
            to: "notes/binary-search.md",
            root: root
        )
        try write(
            "# Cooking\nSimmer tomato sauce and boil pasta.",
            to: "notes/cooking.md",
            root: root
        )
        let embedding = SemanticEmbeddingStub()
        let response = try await makeEngine(
            root: root,
            semanticEmbedding: embedding
        ).search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart,
            areas: [.notes]
        ))

        let result = try #require(response.results.first)
        #expect(response.results.map(\.path) == ["notes/binary-search.md"])
        #expect(result.matchedFields == [.content])
        #expect(result.termCoverage == 0)
        #expect(result.completeQueryFields.isEmpty)
        #expect(result.relevance >= response.minimumRelevance)
        #expect(embedding.calls > 0)
    }

    @Test("Semantic fallback rejects unrelated notes and skips known-term hits")
    func semanticFallbackBoundaries() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Cooking\nSimmer tomato sauce and boil pasta.",
            to: "notes/cooking.md",
            root: root
        )
        let unrelatedEmbedding = SemanticEmbeddingStub()
        let unrelated = try await makeEngine(
            root: root,
            semanticEmbedding: unrelatedEmbedding
        ).search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart,
            areas: [.notes]
        ))
        #expect(unrelated.results.isEmpty)
        #expect(unrelatedEmbedding.calls > 0)

        let knownEmbedding = SemanticEmbeddingStub()
        let known = try await makeEngine(
            root: root,
            semanticEmbedding: knownEmbedding
        ).search(VaultSearchRequest(
            query: "tomato sauce",
            strategy: .smart,
            areas: [.notes]
        ))
        #expect(known.results.first?.path == "notes/cooking.md")
        #expect(knownEmbedding.calls == 0)
    }

    @Test("Weak lexical noise does not suppress a stronger semantic paraphrase")
    func semanticHybridFallback() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Binary search\nCompare a target with the midpoint of a sorted array.",
            to: "notes/binary-search.md",
            root: root
        )
        try write(
            "# Release process\nCutting the range is generic project wording.",
            to: "notes/noise.md",
            root: root
        )
        let embedding = SemanticEmbeddingStub()

        let response = try await makeEngine(
            root: root,
            semanticEmbedding: embedding
        ).search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart,
            areas: [.notes],
            minimumRelevance: 0
        ))

        #expect(response.results.first?.path == "notes/binary-search.md")
        #expect(embedding.calls > 0)
    }

    @Test("Semantic evidence upgrades weak literal evidence in the same passage")
    func semanticUpgradesSamePassage() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Binary search\nCompare a target with the midpoint of a sorted array range.",
            to: "notes/binary-search.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            semanticEmbedding: SemanticEmbeddingStub()
        ).search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart,
            areas: [.notes],
            minimumRelevance: 0
        ))

        let result = try #require(response.results.first)
        #expect(result.path == "notes/binary-search.md")
        #expect(result.termCoverage == 0)
        #expect(result.relevance > 0.8)
    }

    @Test("A bounded semantic scan reports incomplete matching coverage")
    func semanticFallbackWorkLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sections = (0..<513).map {
            "# Recipe \($0)\nTomato sauce preparation number \($0)."
        }.joined(separator: "\n")
        try write(sections, to: "notes/large.md", root: root)

        let response = try await makeEngine(
            root: root,
            semanticEmbedding: SemanticEmbeddingStub()
        ).search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart,
            areas: [.notes]
        ))

        #expect(response.results.isEmpty)
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples.first?.path == "notes/large.md")
        #expect(response.resourceLimitSamples.first?.reason == .matching)
        #expect(response.resourceLimitSamples.first?.impact == .partial)
    }

    @Test("A bounded semantic section reports its unseen suffix")
    func semanticSectionProjectionLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Long note\n"
                + String(repeating: "generic introduction ", count: 400)
                + "\nCompare a target with the midpoint of a sorted array.",
            to: "notes/long.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            semanticEmbedding: SemanticEmbeddingStub()
        ).search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart,
            areas: [.notes]
        ))

        #expect(response.results.isEmpty)
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples.first?.path == "notes/long.md")
        #expect(response.resourceLimitSamples.first?.reason == .matching)
        #expect(response.resourceLimitSamples.first?.impact == .partial)
    }

    @Test("An empty bounded prefix still reports an unseen semantic suffix")
    func semanticWhitespacePrefixLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Long note\n"
                + String(repeating: " ", count: 5_000)
                + "Compare a target with the midpoint of a sorted array.",
            to: "notes/whitespace-prefix.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            semanticEmbedding: SemanticEmbeddingStub()
        ).search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart,
            areas: [.notes]
        ))

        #expect(response.results.isEmpty)
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples.first?.path
            == "notes/whitespace-prefix.md")
        #expect(response.resourceLimitSamples.first?.impact == .omitted)
    }

    @Test("Complete lexical coverage outranks a weak title-only match")
    func lexicalCoverageBeforeFieldBoost() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "---\ntitle: Alpha\n---\nunrelated",
            to: "notes/title.md",
            root: root
        )
        try write(
            "# Other\nalpha beta gamma",
            to: "notes/complete.md",
            root: root
        )

        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(query: "alpha beta gamma", strategy: .lexical)
        )
        #expect(response.results.first?.path == "notes/complete.md")
    }

    @Test("Metadata-only matches do not borrow an unrelated section")
    func metadataPresentation() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Unrelated Heading\nbody without the filename term",
            to: "notes/project-index.md",
            root: root
        )

        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(
                query: "project-index",
                strategy: .exact,
                fields: [.path]
            )
        )
        let result = try #require(response.results.first)
        #expect(result.heading == nil)
        #expect(result.lineStart == 1)
        #expect(result.lineEnd == 1)
        #expect(result.snippet == "notes/project-index.md")
    }

    @Test("Presentation uses the strongest field that produced the rank")
    func strongestMatchPresentation() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "---\ntitle: Alpha Beta\n---\nalpha only",
            to: "notes/presentation.md",
            root: root
        )

        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(query: "Alpha Beta", strategy: .smart)
        )
        let result = try #require(response.results.first)
        #expect(result.snippet == "Alpha Beta")
        #expect(result.heading == nil)
        #expect(result.lineStart == 1)
        #expect(result.matchedFields.contains(.title))
        #expect(result.completeQueryFields == [.title])
        #expect(result.relevance == 1)
        #expect(result.termCoverage == 1)
    }

    @Test("Nested paths, field filters, format filters, and prefixes compose")
    func filters() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("# Alpha\nneedle", to: "notes/work/alpha.md", root: root)
        try write(#"{"value":"needle"}"#, to: "notes/work/data.json", root: root)
        try write("needle", to: "notes/personal/private.log", root: root)
        let engine = try makeEngine(root: root)

        let response = try await engine.search(VaultSearchRequest(
            query: "needle",
            strategy: .exact,
            fields: [.content],
            formats: [.json],
            pathPrefix: "notes/work/"
        ))
        #expect(response.results.map(\.path) == ["notes/work/data.json"])
    }

    @Test("Area filters derive compatible default formats")
    func areaFilters() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("notes-only sentinel", to: "notes/only.md", root: root)
        try write(
            try generatedSearchPDF(pages: ["reference-only sentinel"]),
            to: "references/only.pdf",
            root: root
        )
        let engine = try makeEngine(root: root)

        let notes = try await engine.search(VaultSearchRequest(
            query: "notes-only sentinel",
            strategy: .smart,
            areas: [.notes]
        ))
        #expect(notes.results.map(\.path) == ["notes/only.md"])
        #expect(notes.pdfSummary == .empty)

        let defaultScope = try await engine.search(VaultSearchRequest(
            query: "sentinel",
            strategy: .smart
        ))
        #expect(defaultScope.results.map(\.path) == ["notes/only.md"])
        #expect(defaultScope.pdfSummary == .empty)

        let inferredReferences = try await engine.search(VaultSearchRequest(
            query: "reference-only sentinel",
            strategy: .phrase,
            formats: [.pdf]
        ))
        #expect(inferredReferences.results.map(\.path) == ["references/only.pdf"])

        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "anything",
                formats: [.pdf],
                areas: [.notes]
            ))
        }
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "anything",
                formats: [.pdf],
                pathPrefix: "notes/"
            ))
        }
    }

    @Test("Path prefixes scope traversal before directory budgets apply")
    func pathPrefixScopesTraversal() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<20 {
            try write(
                "unrelated",
                to: "notes/a-sibling/file-\(index).md",
                root: root
            )
        }
        try write("scoped-target", to: "notes/z-scope/target.md", root: root)
        let engine = try makeEngine(
            root: root,
            limits: searchTestLimits(maximumDirectoryEntries: 1)
        )

        let response = try await engine.search(VaultSearchRequest(
            query: "scoped-target",
            strategy: .exact,
            pathPrefix: "notes/z-scope/"
        ))
        #expect(response.results.map(\.path) == ["notes/z-scope/target.md"])
        #expect(!response.coverageIncomplete)

        let missing = try await engine.search(VaultSearchRequest(
            query: "anything",
            strategy: .exact,
            pathPrefix: "notes/not-created/"
        ))
        #expect(missing.results.isEmpty)
        #expect(!missing.coverageIncomplete)
    }

    @Test("Prefixes are canonical directories and cannot expose hidden scopes")
    func safeCanonicalPrefixes() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("canonical-target", to: "notes/work/target.md", root: root)
        try write("hidden-target", to: "notes/.private/secret.md", root: root)
        try write("package-target", to: "notes/Private.app/secret.md", root: root)
        let engine = try makeEngine(root: root)

        let canonical = try await engine.search(VaultSearchRequest(
            query: "canonical-target",
            strategy: .exact,
            pathPrefix: "notes//./work/"
        ))
        #expect(canonical.results.map(\.path) == ["notes/work/target.md"])

        for prefix in [
            "/notes/work/", "notes/work/target.md",
            "notes/.private/", "notes/Private.app/",
        ] {
            await #expect(throws: VaultSearchRequestError.self) {
                _ = try await engine.search(VaultSearchRequest(
                    query: "target",
                    pathPrefix: prefix
                ))
            }
        }
        let broad = try await engine.search(VaultSearchRequest(
            query: "hidden-target",
            strategy: .exact
        ))
        #expect(broad.results.isEmpty)
    }

    @Test("A prefix that becomes a package after validation stays excluded")
    func revalidatesScopedRootBeforeTraversal() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let request = VaultSearchRequest(
            query: "raced-package-target",
            strategy: .exact,
            pathPrefix: "notes/Raced.app/deeper/"
        )
        let validated = try SearchResourcePolicy.validate(
            request,
            capabilities: searchCapabilities(),
            vaultPath: root,
            limits: .default
        )
        try write(
            "raced-package-target",
            to: "notes/Raced.app/deeper/secret.md",
            root: root
        )
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root,
            supportRoot: URL(fileURLWithPath: root)
                .appendingPathComponent(".test-support", isDirectory: true),
            migrateLegacyData: false
        )
        let corpus = try await SearchCorpusBuilder(
            vaultPath: root,
            store: VaultCRUDStore(vaultPath: root),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: dataDirectory.lockDirectoryURL
            ),
            capabilities: searchCapabilities(),
            limits: .default
        ).build(for: validated)

        #expect(corpus.documents.isEmpty)
        #expect(corpus.coverageIncomplete)
    }

    @Test("Symlinks and unsupported or hidden files cannot expand search scope")
    func containment() async throws {
        let root = try makeVault()
        let outside = NSTemporaryDirectory()
            + "VaultSearchOutside-\(UUID().uuidString).md"
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try "outside-only-secret-word".write(
            toFile: outside,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: root + "/notes/leak.md",
            withDestinationPath: outside
        )
        try write("safe-neighbor-word", to: "notes/safe.md", root: root)
        try write("outside-only-secret-word", to: "notes/ignored.txt", root: root)
        try write("outside-only-secret-word", to: "notes/.hidden.md", root: root)
        let engine = try makeEngine(root: root)

        let leak = try await engine.search(VaultSearchRequest(
            query: "outside-only-secret-word",
            strategy: .exact
        ))
        #expect(leak.results.isEmpty)
        let safe = try await engine.search(VaultSearchRequest(
            query: "safe-neighbor-word",
            strategy: .exact
        ))
        #expect(safe.results.map(\.path) == ["notes/safe.md"])
    }

    @Test("Resolved search targets stay bound to their enumerated location")
    func resolvedTargetsMatchLexicalCandidates() throws {
        let root = try makeVault()
        let rootAlias = NSTemporaryDirectory()
            + "VaultSearchRootAlias-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: rootAlias)
            try? FileManager.default.removeItem(atPath: root)
        }
        try write("regular", to: "notes/regular.md", root: root)
        try write("sibling", to: "notes/sibling.md", root: root)
        try FileManager.default.createDirectory(
            atPath: root + "/notes/real-parent",
            withIntermediateDirectories: true
        )
        try write("nested", to: "notes/real-parent/nested.md", root: root)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/notes/final-link.md",
            withDestinationPath: root + "/notes/sibling.md"
        )
        try FileManager.default.createSymbolicLink(
            atPath: root + "/notes/parent-link",
            withDestinationPath: root + "/notes/real-parent"
        )
        try FileManager.default.createSymbolicLink(
            atPath: rootAlias,
            withDestinationPath: root
        )

        let regular = try ReadableFileTarget.resolve(
            path: "notes/regular.md",
            format: .markdown,
            vaultPath: root
        )
        #expect(SearchCorpusBuilder.matchesEnumeratedLocation(
            target: regular,
            candidatePath: "notes/regular.md",
            vaultPath: root
        ))

        let finalLink = try ReadableFileTarget.resolve(
            path: "notes/final-link.md",
            format: .markdown,
            vaultPath: root
        )
        #expect(!SearchCorpusBuilder.matchesEnumeratedLocation(
            target: finalLink,
            candidatePath: "notes/final-link.md",
            vaultPath: root
        ))

        let parentLink = try ReadableFileTarget.resolve(
            path: "notes/parent-link/nested.md",
            format: .markdown,
            vaultPath: root
        )
        #expect(!SearchCorpusBuilder.matchesEnumeratedLocation(
            target: parentLink,
            candidatePath: "notes/parent-link/nested.md",
            vaultPath: root
        ))

        let aliasedRootTarget = try ReadableFileTarget.resolve(
            path: "notes/regular.md",
            format: .markdown,
            vaultPath: rootAlias
        )
        #expect(SearchCorpusBuilder.matchesEnumeratedLocation(
            target: aliasedRootTarget,
            candidatePath: "notes/regular.md",
            vaultPath: rootAlias
        ))
    }

    @Test("Hidden entries consume traversal budget without entering the corpus")
    func hiddenTraversalBudget() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<10 {
            try write(
                "hidden-budget-target",
                to: "notes/.hidden-\(index).md",
                root: root
            )
        }
        try write("visible", to: "notes/visible.md", root: root)

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumDirectoryEntries: 1)
        ).search(VaultSearchRequest(
            query: "hidden-budget-target",
            strategy: .exact
        ))
        #expect(response.results.isEmpty)
        #expect(response.coverageIncomplete)
    }

    @Test("Unsafe legacy text is counted but never projected")
    func sensitiveLegacyFile() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let token = "sk-proj-" + String(repeating: "a", count: 24)
        try write(
            "shared-topic \(token)",
            to: "notes/unsafe.md",
            root: root
        )
        try write("shared-topic safe prose", to: "notes/safe.md", root: root)

        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(query: "shared-topic", strategy: .exact)
        )
        #expect(response.results.map(\.path) == ["notes/safe.md"])
        #expect(response.skippedSensitiveFileCount == 1)
        #expect(!response.results.contains { $0.snippet.contains(token) })
    }

    @Test("HAR credentials are sanitized before matching")
    func harConfidentiality() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let secret = "Bearer " + String(repeating: "z", count: 32)
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[
          {"request":{"method":"GET","url":"https://example.com",
           "headers":[{"name":"Authorization","value":"\(secret)"}]},
           "response":{"status":200},"time":1}
        ]}}
        """
        try write(archive, to: "notes/capture.har", root: root)
        let engine = try makeEngine(root: root)

        let raw = try await engine.search(VaultSearchRequest(
            query: secret,
            strategy: .exact,
            fields: [.content]
        ))
        #expect(raw.results.isEmpty)
        let redacted = try await engine.search(VaultSearchRequest(
            query: HARSensitiveDataSanitizer.redactionMarker,
            strategy: .exact,
            fields: [.content]
        ))
        #expect(redacted.results.map(\.path) == ["notes/capture.har"])
        let result = try #require(redacted.results.first)
        #expect(!result.snippet.contains(secret))
    }

    @Test("Service rejects invalid limits and exposes result truncation")
    func serviceLimits() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("common", to: "notes/a.md", root: root)
        try write("common", to: "notes/b.md", root: root)
        let engine = try makeEngine(root: root)

        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(query: "common", limit: 0))
        }
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(query: "common", limit: 51))
        }
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "common",
                minimumRelevance: -0.01
            ))
        }
        for value in [0, SearchRequestLimits.maximumHitsPerFile + 1] {
            await #expect(throws: VaultSearchRequestError.self) {
                _ = try await engine.search(VaultSearchRequest(
                    query: "common",
                    maxHitsPerFile: value
                ))
            }
        }
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "common",
                cursor: "not-a-search-cursor"
            ))
        }
        let bounded = try await engine.search(VaultSearchRequest(
            query: "common",
            strategy: .exact,
            limit: 1
        ))
        #expect(bounded.results.count == 1)
        #expect(bounded.moreResultsAvailable)
        #expect(!bounded.coverageIncomplete)
        #expect(bounded.resourceLimitedFileCount == 0)
        #expect(bounded.truncated)
    }

    @Test("Direct callers cannot bypass collection and path-prefix limits")
    func directRequestLimits() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let engine = try makeEngine(root: root)

        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "safe",
                fields: [.title, .title]
            ))
        }
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "safe",
                formats: [.markdown, .markdown]
            ))
        }
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "safe",
                areas: [.notes, .notes]
            ))
        }
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "safe",
                pathPrefix: "notes/" + String(repeating: "a", count: 5_000)
            ))
        }
    }

    @Test("File caps retain the lexicographically first eligible notes")
    func deterministicFileCap() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("common", to: "notes/z.md", root: root)
        try write("common", to: "notes/a.md", root: root)
        try write("common", to: "notes/m.md", root: root)

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumFiles: 2)
        ).search(VaultSearchRequest(query: "common", strategy: .exact))
        #expect(response.results.map(\.path) == ["notes/a.md", "notes/m.md"])
        #expect(!response.moreResultsAvailable)
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples == [VaultSearchResourceLimit(
            path: "notes/z.md",
            reason: .fileCount,
            impact: .omitted
        )])
        #expect(response.truncated)
    }

    @Test("An aggregate-oversized file cannot hide later fitting notes")
    func aggregateOversizedFileDoesNotPoisonTraversal() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Test","version":"1"},"entries":[]},"padding":"\(String(repeating: "x", count: 800))"}
        """
        try write(archive, to: "notes/000-oversized.har", root: root)
        try write("# Target\naggregate-neighbor", to: "notes/500-target.md", root: root)
        let engine = try makeEngine(
            root: root,
            limits: searchTestLimits(maximumAggregateBytes: 256)
        )

        let before = try await engine.search(VaultSearchRequest(
            query: "aggregate-neighbor",
            strategy: .exact
        ))
        try FileManager.default.moveItem(
            atPath: root + "/notes/000-oversized.har",
            toPath: root + "/notes/999-oversized.har"
        )
        let after = try await engine.search(VaultSearchRequest(
            query: "aggregate-neighbor",
            strategy: .exact
        ))

        for response in [before, after] {
            #expect(response.results.map(\.path) == ["notes/500-target.md"])
            #expect(response.searchedFileCount == 1)
            #expect(response.skippedFileCount == 0)
            #expect(response.skippedSensitiveFileCount == 0)
            #expect(response.resourceLimitedFileCount == 1)
            #expect(!response.moreResultsAvailable)
            #expect(response.coverageIncomplete)
            #expect(response.truncated)
        }
    }

    @Test("A file that exceeds only the remaining budget cannot hide later notes")
    func residualAggregateBudgetDoesNotPoisonTraversal() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(String(repeating: "a", count: 80), to: "notes/000-prefix.log", root: root)
        let harPrefix = "{\"log\":{\"version\":\"1.2\",\"creator\":{\"name\":\"T\",\"version\":\"1\"},\"entries\":[]},\"padding\":\""
        let harSuffix = "\"}"
        let paddingCount = 250 - harPrefix.utf8.count - harSuffix.utf8.count
        let archive = harPrefix + String(repeating: "p", count: paddingCount) + harSuffix
        #expect(archive.utf8.count == 250)
        try write(archive, to: "notes/100-nonfitting.har", root: root)
        for index in 0..<20 {
            try write("residual", to: "notes/200-later-\(index).md", root: root)
        }

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumAggregateBytes: 300)
        ).search(VaultSearchRequest(query: "residual", strategy: .exact))

        #expect(response.results.count == 20)
        #expect(response.searchedFileCount == 21)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.skippedFileCount == 0)
        #expect(!response.moreResultsAvailable)
        #expect(response.coverageIncomplete)
    }

    @Test("Coverage counters partition malformed, sensitive, and resource-limited files")
    func coverageCounters() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("counter-target", to: "notes/000-safe.md", root: root)
        try write("{invalid", to: "notes/100-invalid.json", root: root)
        try write(
            "counter-target sk_live_" + String(repeating: "a", count: 24),
            to: "notes/200-sensitive.md",
            root: root
        )
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Test","version":"1"},"entries":[]},"padding":"\(String(repeating: "x", count: 1_500))"}
        """
        try write(archive, to: "notes/300-oversized.har", root: root)

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumAggregateBytes: 1_024)
        ).search(VaultSearchRequest(query: "counter-target", strategy: .exact))

        #expect(response.results.map(\.path) == ["notes/000-safe.md"])
        #expect(response.searchedFileCount == 1)
        #expect(response.skippedFileCount == 1)
        #expect(response.skippedSensitiveFileCount == 1)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(!response.moreResultsAvailable)
        #expect(response.coverageIncomplete)
        #expect(response.truncated)
    }

    @Test("Structured archives stop before materializing excessive shapes")
    func structuredValueBudget() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            #"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"needle"}],"edges":[]}"#,
            to: "notes/large-shape.canvas",
            root: root
        )
        try write(
            #"{"log":{"version":"1.2","creator":{"name":"Test"},"entries":[]}}"#,
            to: "notes/large-shape.har",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumStructuredValuesPerFile: 5)
        ).search(VaultSearchRequest(query: "needle", strategy: .exact))
        #expect(response.results.isEmpty)
        #expect(response.resourceLimitedFileCount == 2)
        #expect(response.skippedFileCount == 0)
        #expect(response.coverageIncomplete)
    }

    @Test("Embedded HAR JSON shares the structured-value budget")
    func embeddedHARValueBudget() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let embedded = #"{"values":["#
            + Array(repeating: "0", count: 100).joined(separator: ",")
            + "]}"
        let encodedText = try #require(String(
            data: JSONEncoder().encode(embedded),
            encoding: .utf8
        ))
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[{
          "request":{"method":"POST","url":"https://example.com","postData":{
            "mimeType":"application/json","text":\(encodedText)}},
          "response":{"status":200},"time":1}]}}
        """
        try write(archive, to: "notes/embedded-shape.har", root: root)
        let form = Array(repeating: "safe=value", count: 100)
            .joined(separator: "&")
        let formArchive = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[{
          "request":{"method":"POST","url":"https://example.com","postData":{
            "mimeType":"application/x-www-form-urlencoded","text":"\(form)"}},
          "response":{"status":200},"time":1}]}}
        """
        try write(formArchive, to: "notes/form-shape.har", root: root)

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumStructuredValuesPerFile: 50)
        ).search(VaultSearchRequest(query: "values", strategy: .exact))
        #expect(response.results.isEmpty)
        #expect(response.resourceLimitedFileCount == 2)
        #expect(response.skippedFileCount == 0)
        #expect(response.coverageIncomplete)
    }

    @Test("Defensive JSON nesting ceilings are reported as resource limits")
    func nestingIsResourceLimited() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let nested = String(repeating: "[", count: 513) + "0"
            + String(repeating: "]", count: 513)
        try write(nested, to: "notes/deep.json", root: root)
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[],
        "extension":\(nested)}}
        """
        try write(archive, to: "notes/deep.har", root: root)

        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(query: "anything", strategy: .exact)
        )
        #expect(response.results.isEmpty)
        #expect(response.resourceLimitedFileCount == 2)
        #expect(response.skippedFileCount == 0)
        #expect(response.coverageIncomplete)
    }

    @Test("Sensitive filenames are skipped independently of the query")
    func sensitiveFilenameCoverage() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sensitiveName = "sk_live_" + String(repeating: "a", count: 24)
        try write("shared safe body", to: "notes/\(sensitiveName).md", root: root)
        try write("shared neighbor", to: "notes/safe.md", root: root)
        let engine = try makeEngine(root: root)

        let matching = try await engine.search(VaultSearchRequest(
            query: "shared",
            strategy: .exact
        ))
        let missing = try await engine.search(VaultSearchRequest(
            query: "not-present",
            strategy: .exact
        ))

        for response in [matching, missing] {
            #expect(response.searchedFileCount == 1)
            #expect(response.skippedSensitiveFileCount == 1)
            #expect(response.coverageIncomplete)
        }
        #expect(matching.results.map(\.path) == ["notes/safe.md"])
        #expect(missing.results.isEmpty)
    }

    @Test("Projection validation never synthesizes credentials across fields")
    func independentProjectionFields() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let opaque = String(repeating: "q", count: 32)
        try write(
            "---\ntitle: authorization\n---\n# : \(opaque)\nbody-topic",
            to: "notes/safe-fields.md",
            root: root
        )
        let engine = try makeEngine(root: root)
        let heading = try await engine.search(VaultSearchRequest(
            query: opaque,
            strategy: .exact
        ))
        let body = try await engine.search(VaultSearchRequest(
            query: "body-topic",
            strategy: .exact
        ))

        #expect(heading.results.map(\.path) == ["notes/safe-fields.md"])
        #expect(body.results.map(\.path) == ["notes/safe-fields.md"])
        #expect(heading.skippedSensitiveFileCount == 0)
        #expect(body.skippedSensitiveFileCount == 0)
    }

    @Test("Snippet cleanup never synthesizes a credential across controls")
    func snippetCleaningPreservesCredentialSeparators() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "control-near sk_\u{0000}live_abcdefghijklmnopqrstuvwx",
            to: "notes/control.md",
            root: root
        )

        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(query: "control-near", strategy: .exact)
        )
        let result = try #require(response.results.first)
        #expect(result.path == "notes/control.md")
        #expect(!result.snippet.contains("sk_live_"))
        #expect(response.searchedFileCount == 1)
        #expect(response.skippedSensitiveFileCount == 0)
    }

    @Test("URL credentials in legacy text are never searchable")
    func urlCredentialConfidentiality() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "visit https://alice:supersecretpassword@example.com/private",
            to: "notes/unsafe-url.md",
            root: root
        )
        try write(
            "visit https://example.com/?access%5Ftoken=abcdefghijklmnop1234",
            to: "notes/unsafe-encoded-url.md",
            root: root
        )
        let response = try await makeEngine(root: root).search(
            VaultSearchRequest(query: "example.com", strategy: .exact)
        )
        #expect(response.results.isEmpty)
        #expect(response.skippedSensitiveFileCount == 2)
    }

    @Test("Token ceilings report incomplete coverage, not another result page")
    func tokenCoverageLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "one two three four late-target",
            to: "notes/bounded.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(
                maximumSourceTokensPerField: 3,
                maximumTokenComparisons: 100
            )
        ).search(VaultSearchRequest(
            query: "late-target absent",
            strategy: .lexical,
            fields: [.content]
        ))

        #expect(response.results.isEmpty)
        #expect(response.searchedFileCount == 1)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(!response.moreResultsAvailable)
        #expect(response.coverageIncomplete)
        #expect(response.truncated)
    }

    @Test("Literal occurrence ceilings report partial matching coverage")
    func literalOccurrenceCoverage() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            String(repeating: "cat", count: 100) + " cat",
            to: "notes/dense.log",
            root: root
        )
        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumLiteralOccurrencesPerField: 8)
        ).search(VaultSearchRequest(
            query: "cat",
            strategy: .exact,
            formats: [.log]
        ))
        #expect(response.results.first?.path == "notes/dense.log")
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples.first?.reason == .matching)
    }

    @Test("Literal work is bounded across the complete request")
    func requestWideLiteralOccurrenceCoverage() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("cat", to: "notes/000-whole.md", root: root)
        try write(
            String(repeating: "concatenate ", count: 64),
            to: "notes/999-dense.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(
                maximumLiteralOccurrencesPerField: 64,
                maximumLiteralOccurrencesPerRequest: 3
            )
        ).search(VaultSearchRequest(
            query: "cat",
            strategy: .exact,
            fields: [.content],
            minimumRelevance: 0
        ))

        #expect(response.results.contains { $0.path == "notes/000-whole.md" })
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples.first?.path == "notes/999-dense.md")
        #expect(response.resourceLimitSamples.first?.reason == .matching)
    }

    @Test("Limits in unrequested fields do not make filtered coverage incomplete")
    func fieldSpecificCoverage() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# One\nbody\n# Two\nbody\n# Three\nbody",
            to: "notes/path-target.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumSectionsPerFile: 1)
        ).search(VaultSearchRequest(
            query: "path-target",
            strategy: .exact,
            fields: [.path]
        ))

        #expect(response.results.map(\.path) == ["notes/path-target.md"])
        #expect(response.resourceLimitedFileCount == 0)
        #expect(!response.coverageIncomplete)
        #expect(!response.truncated)
    }

    @Test("Complete front matter stays complete when only the body is capped")
    func frontMatterCoverageIsFieldSpecific() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            """
            ---
            title: Complete Title
            tags: [complete-tag]
            ---
            # One
            body
            # Two
            body
            # Three
            body
            """,
            to: "notes/metadata.md",
            root: root
        )
        let engine = try makeEngine(
            root: root,
            limits: searchTestLimits(
                maximumSectionsPerFile: 1,
                maximumMarkdownLines: 6
            )
        )

        let title = try await engine.search(VaultSearchRequest(
            query: "Complete Title",
            strategy: .exact,
            fields: [.title]
        ))
        let tags = try await engine.search(VaultSearchRequest(
            query: "complete-tag",
            strategy: .exact,
            fields: [.tags]
        ))
        for response in [title, tags] {
            #expect(response.results.map(\.path) == ["notes/metadata.md"])
            #expect(response.resourceLimitedFileCount == 0)
            #expect(!response.coverageIncomplete)
            #expect(!response.truncated)
        }
    }

    @Test("A line cap inside front matter marks unseen tags incomplete")
    func frontMatterCutByLineLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            """
            ---
            title: Visible
            tags: [hidden-tag]
            ---
            body
            """,
            to: "notes/capped-metadata.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumMarkdownLines: 2)
        ).search(VaultSearchRequest(
            query: "hidden-tag",
            strategy: .exact,
            fields: [.tags]
        ))

        #expect(response.results.isEmpty)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.coverageIncomplete)
        #expect(response.truncated)
    }

    @Test("Canvas hits return node coordinates and ignore layout JSON")
    func canvasLocation() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            """
            {"nodes":[{"id":"node-a","type":"text","x":987654,"y":0,
            "width":1,"height":1,"text":"needle body"}],"edges":[]}
            """,
            to: "notes/board.canvas",
            root: root
        )
        let engine = try makeEngine(root: root)
        let found = try await engine.search(VaultSearchRequest(
            query: "needle",
            strategy: .exact,
            fields: [.content]
        ))
        #expect(found.results.first?.location == VaultSearchLocation(
            nodeID: "node-a",
            nodeType: "text",
            field: "text"
        ))
        let layout = try await engine.search(VaultSearchRequest(
            query: "987654",
            strategy: .exact,
            fields: [.content]
        ))
        #expect(layout.results.isEmpty)
    }

    @Test("The final pretty-printed response obeys its byte ceiling")
    func responseByteLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<12 {
            try write(
                "needle " + String(repeating: "content ", count: 80),
                to: "notes/long-result-\(index).md",
                root: root
            )
        }
        let limit = 4_000
        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumResponseBytes: limit)
        ).search(VaultSearchRequest(query: "needle", strategy: .exact, limit: 12))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        #expect(try encoder.encode(response).count <= limit)
        #expect(response.moreResultsAvailable)
        #expect(!response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 0)
        #expect(response.truncated)
    }

    @Test("The bounded top-K selector replaces early weak hits with later strong hits")
    func boundedTopKReplacement() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<10 {
            try write(
                "needle",
                to: String(format: "notes/low-%02d.md", index),
                root: root
            )
        }
        try write(
            "---\ntitle: Needle\n---\nneedle "
                + String(repeating: "padding ", count: 100),
            to: "notes/z-strong.md",
            root: root
        )
        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumCandidates: 3)
        ).search(VaultSearchRequest(
            query: "needle",
            strategy: .exact,
            fields: [.title, .content],
            limit: 3
        ))

        #expect(response.results.first?.path == "notes/z-strong.md")
        #expect(response.results.count == 3)
        #expect(response.moreResultsAvailable)
    }

    @Test("An impossible empty-response ceiling fails instead of lying")
    func impossibleResponseByteLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let engine = try makeEngine(
            root: root,
            limits: searchTestLimits(maximumResponseBytes: 1)
        )
        await #expect(throws: VaultSearchEngine.EngineError.self) {
            _ = try await engine.search(VaultSearchRequest(query: "absent"))
        }
    }

    @Test("Vault processes share one full-corpus search permit")
    func crossProcessAdmission() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("needle", to: "notes/a.md", root: root)
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root,
            supportRoot: URL(fileURLWithPath: root)
                .appendingPathComponent(".test-support", isDirectory: true),
            migrateLegacyData: false
        )
        let contention = SearchLockContentionProbe()
        let lock = POSIXAdvisoryFileLock(
            url: dataDirectory.lockDirectoryURL
                .appendingPathComponent("search.lock"),
            contentionObserver: { contention.mark() }
        )
        let completion = SearchCompletionProbe()
        let engine = try makeEngine(root: root, processSearchLock: lock)
        let lease = try await lock.acquire(.exclusive)
        let task = Task {
            let response = try await engine.search(VaultSearchRequest(query: "needle"))
            await completion.markCompleted()
            return response
        }

        while !contention.observed { await Task.yield() }
        #expect(await !completion.completed)
        lease.release()
        #expect(try await task.value.results.map(\.path) == ["notes/a.md"])
        #expect(await completion.completed)
    }

    @Test("Opaque cursors page through every ranked result without overlap")
    func pagination() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<123 {
            try write(
                "# Generated \(index)\npagination sentinel",
                to: String(format: "notes/result-%03d.md", index),
                root: root
            )
        }
        let engine = try makeEngine(root: root)
        var cursor: String?
        var paths: [String] = []
        var previousOmitted = Int.max

        repeat {
            let response = try await engine.search(VaultSearchRequest(
                query: "pagination sentinel",
                strategy: .smart,
                limit: 17,
                cursor: cursor
            ))
            #expect(response.omittedResultCountLowerBound < previousOmitted)
            previousOmitted = response.omittedResultCountLowerBound
            paths.append(contentsOf: response.results.map(\.path))
            cursor = response.nextCursor
            #expect(response.moreResultsAvailable == (cursor != nil))
        } while cursor != nil

        #expect(paths.count == 123)
        #expect(Set(paths).count == paths.count)
        #expect(paths == paths.sorted())
        #expect(previousOmitted == 0)
    }

    @Test("One search discovers notes and ranked PDF pages with extraction status")
    func unifiedPDFDiscovery() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Concurrency Safety\nA concise note about the sentinel.",
            to: "notes/concurrency.md",
            root: root
        )
        let pdf = try generatedSearchPDF(
            pages: [
                "Table of Contents\nConcurrency safety ........ 3",
                "Preface\nGenerated fixture without the target phrase.",
                "Concurrency safety prevents shared-state corruption in actors.",
            ],
            title: "Generated Concurrency Handbook"
        )
        try write(pdf, to: "references/generated-handbook.pdf", root: root)
        let engine = try makeEngine(root: root)

        let response = try await engine.search(VaultSearchRequest(
            query: "concurrency safety",
            strategy: .phrase,
            areas: [.notes, .references],
            limit: 10,
            maxHitsPerFile: 3
        ))
        #expect(Set(response.results.map(\.area)) == [.notes, .references])
        let pdfResults = response.results.filter { $0.format == .pdf }
        #expect(pdfResults.count == 2)
        #expect(pdfResults.first?.physicalPage == 3)
        #expect(pdfResults.first?.pdfPageKind == .body)
        #expect(pdfResults.last?.physicalPage == 1)
        #expect(pdfResults.last?.pdfPageKind == .tableOfContents)
        #expect(pdfResults.allSatisfy {
            $0.pdfTextExtractionStatus == .extracted
                && $0.area == .references
        })
        #expect(response.pdfSummary.examinedFileCount == 1)
        #expect(response.pdfSummary.extractedFileCount == 1)
        #expect(!response.pdfSummary.ocrPerformed)

        let scoped = try await engine.search(VaultSearchRequest(
            query: "concurrency safety",
            strategy: .phrase,
            formats: [.pdf],
            areas: [.references],
            pathPrefix: "references/",
            maxHitsPerFile: 3
        ))
        #expect(scoped.results.allSatisfy { $0.format == .pdf })
        #expect(scoped.results.map(\.physicalPage) == [3, 1])
    }

    @Test("Oversized PDFs remain discoverable by metadata and disclose missing text")
    func oversizedPDFMetadata() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let pdf = try generatedSearchPDF(pages: [
            "private body sentinel that cannot enter the bounded search"
        ])
        try write(pdf, to: "references/oversized-reference.pdf", root: root)
        let engine = try makeEngine(
            root: root,
            pdfIndexConfiguration: .init(maximumIndexedSourceFileBytes: 32)
        )

        let metadata = try await engine.search(VaultSearchRequest(
            query: "oversized-reference",
            strategy: .exact,
            fields: [.title, .path],
            formats: [.pdf],
            areas: [.references]
        ))
        let result = try #require(metadata.results.first)
        #expect(result.path == "references/oversized-reference.pdf")
        #expect(result.pdfTextExtractionStatus == .contentSkippedFileBytes)
        #expect(metadata.coverageIncomplete)
        #expect(metadata.resourceLimitedFileCount == 1)
        #expect(metadata.resourceLimitSamples.first?.reason == .fileBytes)
        #expect(metadata.resourceLimitSamples.first?.impact == .partial)
        #expect(metadata.pdfSummary.unavailableFileCount == 1)

        let content = try await engine.search(VaultSearchRequest(
            query: "private body sentinel",
            strategy: .exact,
            fields: [.content],
            formats: [.pdf],
            areas: [.references]
        ))
        #expect(content.results.isEmpty)
        #expect(content.coverageIncomplete)
        #expect(content.resourceLimitedFileCount == 1)
        #expect(content.resourceLimitSamples.first?.reason == .fileBytes)
        #expect(content.resourceLimitSamples.first?.impact == .partial)
    }

    @Test("Path-only PDF search reads no bytes and never opens PDFKit")
    func pathOnlyPDFMetadata() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            Data("not a PDF and intentionally unreadable at a zero-byte cap".utf8),
            to: "references/path-only-sentinel.pdf",
            root: root
        )
        let response = try await makeEngine(root: root).search(VaultSearchRequest(
            query: "path-only-sentinel",
            strategy: .exact,
            fields: [.path],
            formats: [.pdf],
            areas: [.references]
        ))

        let result = try #require(response.results.first)
        #expect(result.title == "path only sentinel")
        #expect(result.pdfTextExtractionStatus == .metadataOnly)
        #expect(response.pdfSummary.metadataOnlyFileCount == 1)
        #expect(response.pdfSummary.unavailableFileCount == 0)
        #expect(response.resourceLimitedFileCount == 0)
        #expect(!response.coverageIncomplete)

        let nonTextFields = try await makeEngine(root: root).search(VaultSearchRequest(
            query: "path-only-sentinel",
            strategy: .exact,
            fields: [.path, .tags],
            formats: [.pdf],
            areas: [.references]
        ))
        #expect(nonTextFields.results.first?.pdfTextExtractionStatus
            == .metadataOnly)
        #expect(!nonTextFields.coverageIncomplete)
    }

    @Test("Path-only search validates but does not parse supported note bytes")
    func pathOnlyInvalidMarkdown() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            Data([0xFF, 0xFE, 0xFD]),
            to: "notes/path-only-opaque.md",
            root: root
        )

        let response = try await makeEngine(root: root).search(VaultSearchRequest(
            query: "path-only-opaque",
            strategy: .exact,
            fields: [.path],
            formats: [.markdown],
            areas: [.notes]
        ))

        let result = try #require(response.results.first)
        #expect(result.path == "notes/path-only-opaque.md")
        #expect(result.snippet == "notes/path-only-opaque.md")
        #expect(!response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 0)
    }

    @Test("Title-only PDF search reads metadata without enumerating pages")
    func titleOnlyPDFMetadata() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            try generatedSearchPDF(
                pages: ["page text must not be inspected"],
                title: "Metadata Only Sentinel"
            ),
            to: "references/opaque-name.pdf",
            root: root
        )
        let response = try await makeEngine(
            root: root,
            pdfIndexConfiguration: .init(
                extraction: .init(maximumPages: 0, maximumTextBytes: 0)
            )
        ).search(VaultSearchRequest(
            query: "Metadata Only Sentinel",
            strategy: .exact,
            fields: [.title],
            formats: [.pdf],
            areas: [.references]
        ))

        let result = try #require(response.results.first)
        #expect(result.title == "Metadata Only Sentinel")
        #expect(result.pdfTextExtractionStatus == .metadataOnly)
        #expect(response.pdfSummary.metadataOnlyFileCount == 1)
        #expect(response.pdfSummary.partialFileCount == 0)
        #expect(!response.coverageIncomplete)
    }

    @Test("A bounded-away PDF title reports incomplete title coverage")
    func truncatedPDFTitleCoverage() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            try generatedSearchPDF(
                pages: ["body"],
                title: String(repeating: " ", count: 32) + "Hidden Sentinel"
            ),
            to: "references/fallback.pdf",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumMetadataBytes: 8),
            pdfIndexConfiguration: .init(
                extraction: .init(maximumMetadataBytes: 8)
            )
        ).search(VaultSearchRequest(
            query: "Hidden Sentinel",
            strategy: .exact,
            fields: [.title],
            formats: [.pdf],
            areas: [.references]
        ))

        #expect(response.results.isEmpty)
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples.first?.reason == .projection)
        #expect(response.resourceLimitSamples.first?.impact == .partial)
    }

    @Test("Title-only PDF search distinguishes readable metadata from cannot-open")
    func titleOnlyPDFUnavailableStatuses() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            try generatedLockedSearchPDF(pages: ["protected page text"]),
            to: "references/locked-sentinel.pdf",
            root: root
        )
        let engine = try makeEngine(root: root)

        let locked = try await engine.search(VaultSearchRequest(
            query: "locked-sentinel",
            strategy: .exact,
            fields: [.title, .path],
            formats: [.pdf],
            areas: [.references]
        ))
        #expect(locked.results.first?.pdfTextExtractionStatus == .metadataOnly)
        #expect(locked.pdfSummary.metadataOnlyFileCount == 1)
        #expect(locked.pdfSummary.unavailableFileCount == 0)
        #expect(!locked.coverageIncomplete)

        let lockedContent = try await engine.search(VaultSearchRequest(
            query: "locked-sentinel",
            strategy: .exact,
            fields: [.path, .content],
            formats: [.pdf],
            areas: [.references]
        ))
        #expect(lockedContent.results.first?.pdfTextExtractionStatus == .locked)
        #expect(lockedContent.pdfSummary.unavailableFileCount == 1)
        #expect(lockedContent.coverageIncomplete)

        try write(
            Data("not a PDF".utf8),
            to: "references/broken-sentinel.pdf",
            root: root
        )
        let broken = try await engine.search(VaultSearchRequest(
            query: "broken-sentinel",
            strategy: .exact,
            fields: [.title, .path],
            formats: [.pdf],
            areas: [.references]
        ))
        #expect(broken.results.first?.pdfTextExtractionStatus == .cannotOpen)
        #expect(broken.pdfSummary.unavailableFileCount == 1)
        #expect(broken.coverageIncomplete)
        #expect(broken.resourceLimitedFileCount == 1)
    }

    @Test("PDFs without extractable text remain visible without implying OCR")
    func noTextPDFStatus() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            try generatedSearchPDF(pages: [""]),
            to: "references/scanned-receipt.pdf",
            root: root
        )
        let response = try await makeEngine(root: root).search(VaultSearchRequest(
            query: "scanned-receipt",
            strategy: .exact,
            fields: [.title, .path, .content],
            formats: [.pdf],
            areas: [.references]
        ))
        #expect(response.results.first?.pdfTextExtractionStatus
            == .noExtractableText)
        #expect(response.pdfSummary.noExtractableTextFileCount == 1)
        #expect(!response.pdfSummary.ocrPerformed)
        #expect(!response.coverageIncomplete)
    }

    @Test("Expanded PDF text shares one retained-projection budget")
    func aggregatePDFProjectionBudget() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            try generatedSearchPDF(pages: [String(repeating: "small ", count: 25)]),
            to: "references/000-small.pdf",
            root: root
        )
        try write(
            try generatedSearchPDF(pages: [
                "unique projection sentinel "
                    + String(repeating: "expanded ", count: 150),
            ]),
            to: "references/999-expanded.pdf",
            root: root
        )
        let limits = searchTestLimits(maximumAggregateProjectionBytes: 512)
        let response = try await makeEngine(
            root: root,
            limits: limits,
            pdfIndexConfiguration: .init(
                maximumHydratedTextBytesPerQuery: 512
            )
        ).search(
            VaultSearchRequest(
                query: "unique projection sentinel",
                strategy: .exact,
                fields: [.content],
                formats: [.pdf],
                areas: [.references]
            )
        )
        #expect(response.results.isEmpty)
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.resourceLimitSamples.first?.reason == .projection)
        #expect(response.resourceLimitSamples.first?.impact == .partial)
        // Both source PDFs were completely indexed. The current query's page
        // hydration was projection-limited, which is reported separately from
        // source extraction status.
        #expect(response.pdfSummary.extractedFileCount == 2)
        #expect(response.pdfSummary.partialFileCount == 0)
    }

    @Test("Aggregate section limits reject an oversized file without hiding a later fit")
    func aggregateSectionBudgetPreservesLaterFit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# A\nx\n# B\ny",
            to: "notes/000-two-sections.md",
            root: root
        )
        try write(
            "# Target\naggregate section sentinel with enough filler",
            to: "notes/999-target.md",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumAggregateSections: 1)
        ).search(VaultSearchRequest(
            query: "aggregate section sentinel",
            strategy: .exact,
            fields: [.content]
        ))

        #expect(response.results.map(\.path) == ["notes/999-target.md"])
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.coverageIncomplete)
        #expect(response.resourceLimitSamples.first?.path
            == "notes/000-two-sections.md")
        #expect(response.resourceLimitSamples.first?.reason == .projection)
    }

    @Test("Exhausted section budget prevents later PDF page extraction")
    func aggregateSectionBudgetBoundsPDFExtraction() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            try generatedSearchPDF(pages: [
                "later pdf sentinel " + String(repeating: "padding ", count: 40),
            ]),
            to: "references/999-larger.pdf",
            root: root
        )

        let response = try await makeEngine(
            root: root,
            limits: searchTestLimits(maximumAggregateSections: 0)
        ).search(VaultSearchRequest(
            query: "later pdf sentinel",
            strategy: .exact,
            fields: [.content],
            formats: [.pdf],
            areas: [.references]
        ))

        #expect(response.results.isEmpty)
        #expect(response.pdfSummary.extractedFileCount == 0)
        #expect(response.pdfSummary.partialFileCount == 1)
        #expect(response.resourceLimitedFileCount == 1)
        #expect(response.coverageIncomplete)
    }

    @Test("A mixed text and image-only PDF reports partial extraction")
    func mixedPDFExtractionStatus() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            try generatedSearchPDF(pages: ["mixed text sentinel", ""]),
            to: "references/mixed.pdf",
            root: root
        )
        let response = try await makeEngine(root: root).search(VaultSearchRequest(
            query: "mixed text sentinel",
            strategy: .exact,
            fields: [.content],
            formats: [.pdf],
            areas: [.references]
        ))
        #expect(response.results.first?.pdfTextExtractionStatus == .partial)
        #expect(response.pdfSummary.partialFileCount == 1)
        #expect(response.coverageIncomplete)
    }

    @Test("A cursor is bound to every result-shaping request option")
    func cursorBinding() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("cursor sentinel", to: "notes/a.md", root: root)
        try write("cursor sentinel", to: "notes/b.md", root: root)
        let engine = try makeEngine(root: root)
        let first = try await engine.search(VaultSearchRequest(
            query: "cursor sentinel",
            strategy: .smart,
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)

        let second = try await engine.search(VaultSearchRequest(
            query: "cursor sentinel",
            strategy: .smart,
            limit: 1,
            cursor: cursor
        ))
        #expect(second.results.map(\.path) == ["notes/b.md"])

        for changed in [
            VaultSearchRequest(
                query: "different",
                strategy: .smart,
                limit: 1,
                cursor: cursor
            ),
            VaultSearchRequest(
                query: "cursor sentinel",
                strategy: .exact,
                limit: 1,
                cursor: cursor
            ),
            VaultSearchRequest(
                query: "cursor sentinel",
                strategy: .smart,
                fields: [.title],
                limit: 1,
                cursor: cursor
            ),
            VaultSearchRequest(
                query: "cursor sentinel",
                strategy: .smart,
                limit: 1,
                minimumRelevance: 0,
                cursor: cursor
            ),
            VaultSearchRequest(
                query: "cursor sentinel",
                strategy: .smart,
                limit: 1,
                maxHitsPerFile: 2,
                cursor: cursor
            ),
        ] {
            await #expect(throws: VaultSearchRequestError.self) {
                _ = try await engine.search(changed)
            }
        }
    }

    @Test("Oversized locators cannot produce a non-advancing cursor")
    func oversizedLocatorPagination() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let identifier = String(
            repeating: "node-x",
            count: SearchRequestLimits.maximumLocatorBytes
        )
        let canvas = """
        {"nodes":[{"id":"\(identifier)","type":"text","x":0,"y":0,
        "width":1,"height":1,"text":"cursor locator sentinel"}],"edges":[]}
        """
        try write(canvas, to: "notes/000-locator.canvas", root: root)
        try write(
            "cursor locator sentinel",
            to: "notes/999-later.md",
            root: root
        )
        let engine = try makeEngine(root: root)
        let first = try await engine.search(VaultSearchRequest(
            query: "cursor locator sentinel",
            strategy: .exact,
            limit: 1
        ))
        #expect(first.results.first?.path == "notes/000-locator.canvas")
        #expect(first.results.first?.location == nil)
        #expect(first.coverageIncomplete)
        let cursor = try #require(first.nextCursor)

        let second = try await engine.search(VaultSearchRequest(
            query: "cursor locator sentinel",
            strategy: .exact,
            limit: 1,
            cursor: cursor
        ))
        #expect(second.results.map(\.path) == ["notes/999-later.md"])
    }

    @Test("Continuation rejects a corpus changed between pages")
    func cursorCorpusRevision() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("revision sentinel", to: "notes/a.md", root: root)
        try write("revision sentinel", to: "notes/b.md", root: root)
        let engine = try makeEngine(root: root)
        let first = try await engine.search(VaultSearchRequest(
            query: "revision sentinel",
            strategy: .exact,
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)
        try write("revision sentinel changed", to: "notes/b.md", root: root)

        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "revision sentinel",
                strategy: .exact,
                limit: 1,
                cursor: cursor
            ))
        }
    }

    @Test("Continuation binds skipped versus admitted projection outcomes")
    func cursorProjectionOutcome() async throws {
        let root = try makeVault()
        let pdfPath = root + "/references/outcome-sentinel.pdf"
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: pdfPath
            )
            try? FileManager.default.removeItem(atPath: root)
        }
        try write(
            "# Outcome Sentinel A",
            to: "notes/outcome-sentinel-a.md",
            root: root
        )
        try write(
            "# Outcome Sentinel B",
            to: "notes/outcome-sentinel-b.md",
            root: root
        )
        try write(
            try generatedSearchPDF(
                pages: ["body"],
                title: "Outcome Sentinel PDF"
            ),
            to: "references/outcome-sentinel.pdf",
            root: root
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: pdfPath
        )
        let engine = try makeEngine(root: root)
        let first = try await engine.search(VaultSearchRequest(
            query: "outcome sentinel",
            strategy: .exact,
            fields: [.title, .path],
            formats: [.markdown, .pdf],
            areas: [.notes, .references],
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pdfPath
        )
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await engine.search(VaultSearchRequest(
                query: "outcome sentinel",
                strategy: .exact,
                fields: [.title, .path],
                formats: [.markdown, .pdf],
                areas: [.notes, .references],
                limit: 1,
                cursor: cursor
            ))
        }
    }

    @Test("Callers can request several distinct passages from one file")
    func multiplePassagesPerFile() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            """
            # First
            passage needle alpha

            # Second
            passage needle beta

            # Third
            passage needle gamma
            """,
            to: "notes/multi.md",
            root: root
        )
        let engine = try makeEngine(root: root)

        let defaultResponse = try await engine.search(VaultSearchRequest(
            query: "passage needle",
            strategy: .smart
        ))
        #expect(defaultResponse.results.count == 1)

        let expanded = try await engine.search(VaultSearchRequest(
            query: "passage needle",
            strategy: .smart,
            maxHitsPerFile: 3
        ))
        #expect(expanded.results.count == 3)
        #expect(Set(expanded.results.map(\.path)) == ["notes/multi.md"])
        #expect(expanded.results.map(\.heading) == ["First", "Second", "Third"])
        #expect(Set(expanded.results.map(\.lineStart)).count == 3)
    }

    @Test("Smart enforces one per-file passage ceiling across both passes")
    func smartPassesShareHitLimit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            """
            # Phrase One
            alpha beta

            # Phrase Two
            alpha beta

            # Token One
            alpha, beta

            # Token Two
            alpha, beta
            """,
            to: "notes/mixed-passages.md",
            root: root
        )
        let response = try await makeEngine(root: root).search(VaultSearchRequest(
            query: "alpha beta",
            strategy: .smart,
            maxHitsPerFile: 2
        ))
        #expect(response.results.count == 2)
        #expect(Set(response.results.map(\.lineStart)).count == 2)
    }

    @Test("Distributed metadata evidence preserves distinct local passages")
    func distributedPassagePresentation() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            """
            ---
            title: Focus
            ---
            # First
            engine one

            # Second
            engine two

            # Third
            engine three
            """,
            to: "notes/distributed.md",
            root: root
        )
        let response = try await makeEngine(root: root).search(VaultSearchRequest(
            query: "focus engine",
            strategy: .smart,
            maxHitsPerFile: 3
        ))
        #expect(response.results.count == 3)
        #expect(response.results.map(\.heading) == ["First", "Second", "Third"])
        #expect(response.results.allSatisfy { $0.snippet.contains("engine") })
    }

    @Test("A canceled search leaves the shared admission queue immediately")
    func admissionCancellation() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("needle", to: "notes/a.md", root: root)
        let gate = AsyncExclusiveGate()
        let hold = SearchAdmissionHold()
        let engine = try makeEngine(root: root, admissionGate: gate)

        let holder = Task {
            try await gate.withPermit { await hold.enterAndWait() }
        }
        await hold.waitUntilEntered()
        let queued = Task {
            try await engine.search(VaultSearchRequest(query: "needle"))
        }
        while await gate.waitingCount == 0 { await Task.yield() }
        queued.cancel()

        do {
            _ = try await queued.value
            Issue.record("Expected queued search cancellation")
        } catch is CancellationError {
            // The search never acquires the whole-vault scan permit.
        }
        #expect(await gate.waitingCount == 0)
        await hold.release()
        try await holder.value
    }

    @Test("A full search queue returns a bounded retryable error")
    func admissionCapacity() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("needle", to: "notes/a.md", root: root)
        let gate = AsyncExclusiveGate(maximumWaiters: 0)
        let hold = SearchAdmissionHold()
        let engine = try makeEngine(root: root, admissionGate: gate)
        let holder = Task {
            try await gate.withPermit { await hold.enterAndWait() }
        }
        await hold.waitUntilEntered()

        do {
            _ = try await engine.search(VaultSearchRequest(query: "needle"))
            Issue.record("Expected search capacity rejection")
        } catch VaultSearchRequestError.searchBusy {
            // The request is not retained behind the active full-vault scan.
        }
        #expect(await gate.waitingCount == 0)
        await hold.release()
        try await holder.value
    }
}

private actor SearchAdmissionHold {
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SearchCompletionProbe {
    private(set) var completed = false

    func markCompleted() { completed = true }
}

private final class SearchLockContentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var observed: Bool { lock.withLock { value } }

    func mark() {
        lock.withLock { value = true }
    }
}
