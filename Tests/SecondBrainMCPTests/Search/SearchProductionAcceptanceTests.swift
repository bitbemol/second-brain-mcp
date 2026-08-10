import Foundation
import Testing
@testable import second_brain_mcp

/// Generated, copyright-free acceptance fixtures modeled on a real HAR-heavy vault.
@Suite("Vault search production acceptance")
struct SearchProductionAcceptanceTests {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory()
            + "SearchProductionAcceptanceTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ text: String, _ path: String, root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func engine(
        root: String,
        limits: SearchResourceLimits = .default
    ) throws -> VaultSearchEngine {
        let support = try VaultDataDirectory.prepare(
            vaultPath: root,
            supportRoot: URL(fileURLWithPath: root)
                .appendingPathComponent(".test-support", isDirectory: true),
            migrateLegacyData: false
        )
        let capabilities = SearchCapabilities(fileCapabilities: FileCapabilities(
            formats: FileFormat.allCases.filter(\.isTextual).map {
                .init(format: $0, operations: [.read: [.notes]])
            }
        ))
        return VaultSearchEngine(
            vaultPath: root,
            capabilities: capabilities,
            store: VaultCRUDStore(vaultPath: root),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: support.lockDirectoryURL
            ),
            limits: limits
        )
    }

    private func generatedHAR(padding: String, sentinel: String = "") -> String {
        """
        {"log":{"version":"1.2","creator":{"name":"Generated Fixture","version":"1"},"entries":[
          {"request":{"method":"GET","url":"https://example.invalid/generated","headers":[]},
           "response":{"status":200,"headers":[],"content":{"size":0,"mimeType":"text/plain","text":"\(sentinel)"}},"time":1}
        ]},"padding":"\(padding)"}
        """
    }

    @Test("Smart preserves exact recall after noisy archives exhaust relaxed work")
    func smartContainsExactResults() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let noise = Array(repeating: "benign", count: 1_000).joined(separator: " ")
        for index in 0..<3 {
            try write(
                generatedHAR(padding: noise + " archive\(index)"),
                "notes/000-capture-\(index).har",
                root: root
            )
        }
        try write(
            "# Commit verification\nunique durable commit sentinel",
            "notes/900-target.md",
            root: root
        )
        let service = try engine(
            root: root,
            limits: searchTestLimits(
                maximumTokenComparisons: 64,
                maximumFuzzyComparisons: 32,
                maximumEditDistanceCells: 128
            )
        )
        let request = VaultSearchRequest(
            query: "unique durable commit sentinel",
            strategy: .exact,
            limit: 50
        )
        let exact = try await service.search(request)
        let smartRequest = VaultSearchRequest(
            query: request.query,
            strategy: .smart,
            limit: 50
        )
        let smart = try await service.search(smartRequest)
        let repeated = try await service.search(smartRequest)

        #expect(Set(exact.results.map(\.path)).isSubset(of: Set(smart.results.map(\.path))))
        #expect(smart.results.contains { $0.path == "notes/900-target.md" })
        #expect(smart.searchedFileCount == exact.searchedFileCount)
        #expect(smart.searchedFileCount == 4)
        #expect(smart == repeated)
        #expect(!smart.resourceLimitSamples.isEmpty)
        #expect(smart.resourceLimitSamples.allSatisfy {
            $0.reason == .matching && $0.impact == .partial
        })
    }

    @Test("Fair smart work preserves a late typo-only hit")
    func lateFuzzyRecall() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<10 {
            try write("alpha", String(format: "notes/a-%02d.md", index), root: root)
        }
        try write("focus", "notes/z-target.md", root: root)
        let service = try engine(
            root: root,
            limits: searchTestLimits(
                maximumTokenComparisons: 55,
                maximumFuzzyComparisons: 22,
                maximumEditDistanceCells: 330
            )
        )
        let response = try await service.search(VaultSearchRequest(
            query: "focsu",
            strategy: .smart,
            fields: [.content],
            formats: [.markdown],
            limit: 50
        ))
        #expect(response.results.map(\.path) == ["notes/z-target.md"])
        #expect(response.searchedFileCount == 11)
    }

    @Test("Resource diagnostics are bounded ordered and do not hide later notes")
    func resourceDiagnostics() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<10 {
            try write(
                generatedHAR(padding: String(repeating: "x", count: 1_000)),
                String(format: "notes/capture-%02d.har", index),
                root: root
            )
        }
        try write("# Safe\nlate-safe-sentinel", "notes/target.md", root: root)
        let response = try await engine(
            root: root,
            limits: searchTestLimits(maximumFileBytes: 512)
        ).search(VaultSearchRequest(
            query: "late-safe-sentinel",
            strategy: .smart,
            limit: 50
        ))

        #expect(response.results.map(\.path) == ["notes/target.md"])
        #expect(response.resourceLimitedFileCount == 10)
        #expect(response.resourceLimitSamples.count
            == SearchRequestLimits.maximumResourceLimitSamples)
        #expect(response.resourceLimitSamples.map(\.path)
            == response.resourceLimitSamples.map(\.path).sorted())
        #expect(response.resourceLimitSamples.allSatisfy {
            $0.reason == .fileBytes && $0.impact == .omitted
        })
        #expect(response.resourceLimitSamples.first?.path == "notes/capture-00.har")
        #expect(response.resourceLimitSamples.last?.path == "notes/capture-07.har")
    }

    @Test("Filtered smart recall still contains filtered exact recall")
    func filteredExactSubset() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("# Target\nfiltered exact sentinel", "notes/work/target.md", root: root)
        try write("filtered exact sentinel", "notes/outside.md", root: root)
        try write(#"{"value":"filtered exact sentinel"}"#, "notes/work/data.json", root: root)
        let service = try engine(root: root)
        let exact = try await service.search(VaultSearchRequest(
            query: "filtered exact sentinel",
            strategy: .exact,
            fields: [.content],
            formats: [.markdown],
            pathPrefix: "notes/work/",
            limit: 50
        ))
        let smart = try await service.search(VaultSearchRequest(
            query: "filtered exact sentinel",
            strategy: .smart,
            fields: [.content],
            formats: [.markdown],
            pathPrefix: "notes/work/",
            limit: 50
        ))
        #expect(Set(exact.results.map(\.path)).isSubset(of: Set(smart.results.map(\.path))))
        #expect(smart.results.map(\.path) == ["notes/work/target.md"])
    }

    @Test("Default smart reaches a generated HAR-heavy vault deterministically")
    func skewedCorpusSmoke() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<234 {
            try write(
                "# Generated note \(index)\nordinary bounded prose",
                String(format: "notes/note-%03d.md", index),
                root: root
            )
        }
        let padding = Array(repeating: "archive-noise", count: 8_000)
            .joined(separator: " ")
        for index in 0..<10 {
            try write(
                generatedHAR(padding: padding + " \(index)"),
                String(format: "notes/capture-%02d.har", index),
                root: root
            )
        }
        try write(
            "# Late target\nproduction acceptance sentinel",
            "notes/zz-target.md",
            root: root
        )
        let service = try engine(root: root)
        let request = VaultSearchRequest(
            query: "production acceptance sentinel",
            strategy: .smart,
            limit: 50
        )
        let first = try await service.search(request)
        let second = try await service.search(request)

        #expect(first == second)
        #expect(first.searchedFileCount == 245)
        #expect(first.results.first?.path == "notes/zz-target.md")
        #expect(first.resourceLimitedFileCount == 0)
        #expect(!first.coverageIncomplete)
    }

    @Test("Relevance rejects one-term noise while preserving complete fuzzy recall")
    func relevanceFloor() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("# Rollout\nrollout", "notes/rollout.md", root: root)
        try write("# Chart\nchart", "notes/chart.md", root: root)
        try write(
            "# Deployment\nkubernetes helm chart rollout",
            "notes/full.md",
            root: root
        )
        try write(
            "# Git Safety\nconcurrent agents coordinate the git index lock",
            "notes/fuzzy.md",
            root: root
        )
        let service = try engine(root: root)

        let precise = try await service.search(VaultSearchRequest(
            query: "kubernetes helm chart rollout",
            strategy: .smart
        ))
        #expect(precise.results.map(\.path) == ["notes/full.md"])
        #expect(precise.results.allSatisfy {
            $0.relevance >= precise.minimumRelevance
        })

        let broad = try await service.search(VaultSearchRequest(
            query: "kubernetes helm chart rollout",
            strategy: .smart,
            minimumRelevance: 0
        ))
        #expect(broad.results.contains { $0.path == "notes/rollout.md" })
        #expect(broad.results.contains { $0.path == "notes/chart.md" })
        #expect(broad.results.first?.path == "notes/full.md")
        #expect(broad.results.first?.termCoverage == 1)
        #expect(broad.results.first?.relevance ?? 0 > 0.90)

        let typo = try await service.search(VaultSearchRequest(
            query: "concurent git lok",
            strategy: .smart
        ))
        #expect(typo.results.first?.path == "notes/fuzzy.md")
        #expect(typo.results.first?.termCoverage == 1)
    }

    @Test("Conversational questions ignore filler words and retain the idea")
    func conversationalRecall() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Removing an app completely\nUninstall app leftovers and files from Library folders.",
            "notes/library-cleanup.md",
            root: root
        )
        try write(
            "# Actor isolation\nConcurrent shared state is protected from data races.",
            "notes/actor-isolation.md",
            root: root
        )
        try write(
            "# Binary search\nLocate a target in a sorted array by checking the midpoint and halving the remaining interval.",
            "notes/binary-search.md",
            root: root
        )
        try write("# Applications\nGeneral application notes.", "notes/apps.md", root: root)
        let service = try engine(root: root)

        let uninstall = try await service.search(VaultSearchRequest(
            query: "where should I look for files left behind after uninstalling an app?",
            strategy: .smart
        ))
        #expect(uninstall.results.first?.path == "notes/library-cleanup.md")
        #expect(uninstall.results.first?.termCoverage ?? 0 >= 0.70)

        let concurrency = try await service.search(VaultSearchRequest(
            query: "how can I prevent concurrent access from corrupting shared state?",
            strategy: .smart
        ))
        #expect(concurrency.results.first?.path == "notes/actor-isolation.md")
        #expect(concurrency.results.first?.relevance
            ?? 0 >= SearchRequestLimits.defaultMinimumRelevance)

        let semantic = try await service.search(VaultSearchRequest(
            query: "find an item in an ordered collection by repeatedly cutting the range in half",
            strategy: .smart
        ))
        #expect(semantic.results.first?.path == "notes/binary-search.md")
        #expect(semantic.results.first?.termCoverage == 0)
        #expect(semantic.results.first?.completeQueryFields.isEmpty == true)
    }

    @Test("Title specificity outranks long titles and embedded substrings")
    func preciseTitleRanking() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("# Search syntax\noperators", "notes/search-syntax.md", root: root)
        try write(
            "# Pattern modified binary search\nalgorithm",
            "notes/pattern.md",
            root: root
        )
        try write("# Research\nmethod", "notes/research.md", root: root)
        let smart = try await engine(root: root).search(VaultSearchRequest(
            query: "search",
            strategy: .smart,
            minimumRelevance: 0
        ))
        #expect(smart.results.map(\.path) == [
            "notes/search-syntax.md", "notes/pattern.md",
        ])
        #expect(smart.results[0].relevance > smart.results[1].relevance)
        #expect(!smart.results.contains { $0.path == "notes/research.md" })

        let literal = try await engine(root: root).search(VaultSearchRequest(
            query: "search",
            strategy: .exact,
            minimumRelevance: 0
        ))
        #expect(literal.results.last?.path == "notes/research.md")
        #expect(literal.results.last?.relevance ?? 1 < literal.results.first?.relevance ?? 0)
    }

    @Test("Fuzzy terms can combine across title and body")
    func distributedFuzzyTypos() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# Binary search\nRotated array implementation details.",
            "notes/binary-search.md",
            root: root
        )
        let service = try engine(root: root)
        for strategy in [SearchStrategy.fuzzy, .smart] {
            let response = try await service.search(VaultSearchRequest(
                query: "bniary serach rotated array",
                strategy: strategy
            ))
            #expect(response.results.first?.path == "notes/binary-search.md")
            #expect(response.results.first?.termCoverage == 1)
        }
    }

    @Test("Field evidence distinguishes contribution from whole-query matches")
    func truthfulFieldEvidence() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "---\ntitle: Focus Runbook\n---\nengine tuning",
            "notes/distributed.md",
            root: root
        )
        let response = try await engine(root: root).search(VaultSearchRequest(
            query: "focus engine",
            strategy: .smart
        ))
        let result = try #require(response.results.first)
        #expect(result.matchedFields == [.title, .content])
        #expect(result.completeQueryFields.isEmpty)
        #expect(result.termCoverage == 1)
        #expect(result.relevance >= response.minimumRelevance)
        #expect(result.relevance < 0.90)
    }

    @Test("Symbolic credential documentation remains discoverable end to end")
    func symbolicPlaceholder() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            "# LiteLLM setup\nAuthorization: Bearer ACTUAL_LITELLM_API_KEY",
            "notes/setup.md",
            root: root
        )
        let response = try await engine(root: root).search(VaultSearchRequest(
            query: "ACTUAL_LITELLM_API_KEY",
            strategy: .exact
        ))
        #expect(response.results.map(\.path) == ["notes/setup.md"])
        #expect(response.searchedFileCount == 1)
        #expect(response.skippedSensitiveFileCount == 0)
    }

    @Test("Generated JSON CSV log and HAR content are searchable safely")
    func textualFormatMatrix() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(
            #"{"nested":{"message":"json-format-sentinel"}}"#,
            "notes/data.json",
            root: root
        )
        try write(
            "\"id\",\"message\"\r\n\"1\",\"csv-format-sentinel, with\nnewline\"",
            "notes/table.csv",
            root: root
        )
        try write("2026-01-01 log-format-sentinel", "notes/app.log", root: root)
        try write(
            generatedHAR(padding: "bounded", sentinel: "har-format-sentinel"),
            "notes/capture.har",
            root: root
        )
        let service = try engine(root: root)
        let fixtures: [(String, String, FileFormat)] = [
            ("json-format-sentinel", "notes/data.json", .json),
            ("csv-format-sentinel", "notes/table.csv", .csv),
            ("log-format-sentinel", "notes/app.log", .log),
            ("har-format-sentinel", "notes/capture.har", .har),
        ]
        for (query, path, format) in fixtures {
            for strategy in [SearchStrategy.exact, .smart] {
                let response = try await service.search(VaultSearchRequest(
                    query: query,
                    strategy: strategy,
                    fields: [.content],
                    formats: [format]
                ))
                #expect(response.results.map(\.path) == [path])
                #expect(response.results.first?.format == format)
            }
        }
    }
}
