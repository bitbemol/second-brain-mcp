import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault search engine")
struct VaultSearchEngineTests {
    private func makeEngine(
        root: String,
        limits: SearchResourceLimits = .default,
        admissionGate: AsyncExclusiveGate = AsyncExclusiveGate()
    ) throws -> VaultSearchEngine {
        let supportRoot = URL(fileURLWithPath: root)
            .appendingPathComponent(".test-support", isDirectory: true)
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root,
            supportRoot: supportRoot,
            migrateLegacyData: false
        )
        let fileCapabilities = FileCapabilities(formats: FileFormat.allCases
            .filter(\.isTextual)
            .map { format in
                .init(format: format, operations: [.read: [.notes]])
            })
        return VaultSearchEngine(
            vaultPath: root,
            capabilities: SearchCapabilities(fileCapabilities: fileCapabilities),
            store: VaultCRUDStore(vaultPath: root),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: dataDirectory.lockDirectoryURL
            ),
            limits: limits,
            admissionGate: admissionGate
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
        let bounded = try await engine.search(VaultSearchRequest(
            query: "common",
            strategy: .exact,
            limit: 1
        ))
        #expect(bounded.results.count == 1)
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
        #expect(response.truncated)
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
