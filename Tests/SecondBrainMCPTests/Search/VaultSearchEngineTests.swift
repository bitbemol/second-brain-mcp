import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault search engine")
struct VaultSearchEngineTests {
    private func searchCapabilities() -> SearchCapabilities {
        let fileCapabilities = FileCapabilities(formats: FileFormat.allCases
            .filter(\.isTextual)
            .map { format in
                .init(format: format, operations: [.read: [.notes]])
            })
        return SearchCapabilities(fileCapabilities: fileCapabilities)
    }

    private func makeEngine(
        root: String,
        limits: SearchResourceLimits = .default,
        admissionGate: AsyncExclusiveGate? = nil,
        processSearchLock: POSIXAdvisoryFileLock? = nil
    ) throws -> VaultSearchEngine {
        let supportRoot = URL(fileURLWithPath: root)
            .appendingPathComponent(".test-support", isDirectory: true)
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root,
            supportRoot: supportRoot,
            migrateLegacyData: false
        )
        return VaultSearchEngine(
            vaultPath: root,
            capabilities: searchCapabilities(),
            store: VaultCRUDStore(vaultPath: root),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: dataDirectory.lockDirectoryURL
            ),
            limits: limits,
            admissionGate: admissionGate,
            processSearchLock: processSearchLock
        )
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory()
            + "VaultSearchEngineTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
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
        let limit = 1_200
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
        let lock = POSIXAdvisoryFileLock(
            url: dataDirectory.lockDirectoryURL
                .appendingPathComponent("search.lock")
        )
        let completion = SearchCompletionProbe()
        let engine = try makeEngine(root: root, processSearchLock: lock)
        let lease = try await lock.acquire(.exclusive)
        let task = Task {
            let response = try await engine.search(VaultSearchRequest(query: "needle"))
            await completion.markCompleted()
            return response
        }

        try await Task.sleep(for: .milliseconds(40))
        #expect(await !completion.completed)
        lease.release()
        #expect(try await task.value.results.map(\.path) == ["notes/a.md"])
        #expect(await completion.completed)
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
