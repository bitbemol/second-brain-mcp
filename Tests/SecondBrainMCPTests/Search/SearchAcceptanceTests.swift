import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct SearchAcceptanceTests {
    @Test("Discovery advertises only effective search representations")
    func runtimeDiscoveryFormats() async throws {
        try await withRuntime { runtime, root in
            let tool = try await discoveredTool(runtime: runtime, root: root, search: runtime.search)
            #expect(try formatNames(tool) == Set(["markdown", "canvas", "har", "patch", "log", "json", "csv", "pdf"]))
        }
    }

    @Test("Unsupported image search explains capability instead of blaming a valid directory")
    func unsupportedFormatHasActionableError() async throws {
        try await withRuntime { runtime, root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("notes/project"), withIntermediateDirectories: true)
            let result = try await SearchToolController(search: runtime.search).call(.init(
                name: "search_vault", arguments: [
                    "location": .string("notes"), "directory": .string("project"),
                    "formats": .array([.string("png")]), "query": .string("needle"),
                ]
            ))
            #expect(result.isError == true)
            let message = try firstText(result)
            #expect(message.contains("png"))
            #expect(message.lowercased().contains("search"))
            #expect(message.lowercased().contains("not supported") || message.lowercased().contains("unsupported"))
            #expect(message.contains("list_files") && message.contains("read_file"))
            #expect(!message.contains("existing visible"))
            #expect(!message.contains(root.path))
            #expect(message.utf8.count <= 1_024)
        }
    }

    @Test("Custom providers participate in both discovery and actual search")
    func customProviderDiscoveryMatchesExecution() async throws {
        try await withRuntime { runtime, root in
            try Data("synthetic provider input".utf8).write(to: root.appendingPathComponent("notes/test.png"))
            let source = SearchCorpusBuilder(
                vaultPath: root.path,
                capabilities: FileCapabilities(formats: [
                    .init(format: .png, operations: [.read: [.notes]]),
                    .init(format: .jpeg, operations: [.read: [.notes]]),
                ]),
                captureStore: searchCaptureFixture(root),
                access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".test-access.lock")),
                customProviders: [.png: SyntheticImageProvider()]
            )
            let service = VaultSearchEngine(source: source)
            let tool = try await discoveredTool(runtime: runtime, root: root, search: service)
            #expect(try formatNames(tool) == ["png"])
            let response = try await service.search(.init(location: .notes, formats: [.png], query: "needle"))
            #expect(response.results == [.init(path: "notes/test.png", format: .png)])
            #expect(response.coverage.complete)
        }
    }

    @Test("Search counts every failed format beyond the bounded path samples")
    func exactFormatCoverageAndNarrowing() async throws {
        try await withRuntime { runtime, root in
            try Data("needle".utf8).write(to: root.appendingPathComponent("notes/healthy.md"))
            try Data([0xff]).write(to: root.appendingPathComponent("notes/invalid.json"))
            for index in 0..<4 {
                let file = root.appendingPathComponent("notes/oversized-\(index).har")
                try Data().write(to: file)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(FileFormat.har.maximumFileBytes + 1))
            }
            let controller = SearchToolController(search: runtime.search)
            let broad = try await controller.call(.init(name: "search_vault", arguments: [
                "location": .string("notes"), "query": .string("absent"),
            ]))
            try #require(broad.isError != true)
            let coverage = try #require(broad.structuredContent?.objectValue?["coverage"]?.objectValue)
            #expect(coverage["complete"] == .bool(false))
            #expect(coverage["failed_files"] == .int(5))
            #expect(coverage["failed_by_format"] == .object(["har": .int(4), "json": .int(1)]))
            let completeFormats = try #require(coverage["complete_formats"]?.arrayValue)
            #expect(Set(completeFormats.compactMap(\.stringValue)) == ["markdown", "canvas", "patch", "log", "csv"])
            #expect(broad.structuredContent?.objectValue?["results"] == .array([]))
            #expect(coverage["samples"]?.arrayValue?.count == 3)
            #expect(coverage["samples_truncated"] == .bool(true))
            let fallback = try JSONDecoder().decode(Value.self, from: Data(firstText(broad).utf8))
            #expect(fallback == broad.structuredContent)

            let narrowed = try await controller.call(.init(name: "search_vault", arguments: [
                "location": .string("notes"), "query": .string("absent"),
                "formats": .array([.string("markdown")]),
            ]))
            try #require(narrowed.isError != true)
            #expect(narrowed.structuredContent?.objectValue?["coverage"] == .object(["complete": .bool(true)]))
            #expect(narrowed.structuredContent?.objectValue?["results"] == .array([]))
        }
    }

    @Test("Format counts stay exact at the file ceiling without expanding the coverage budget")
    func formatCoverageRemainsBounded() async throws {
        let result = try await SearchToolController(
            search: VaultSearchEngine(source: AllFormatsFailureSource())
        ).call(.init(name: "search_vault", arguments: [
            "location": .string("notes"), "query": .string("needle"),
        ]))
        try #require(result.isError != true)
        let coverage = try #require(result.structuredContent?.objectValue?["coverage"])
        let object = try #require(coverage.objectValue)
        let counts = try #require(object["failed_by_format"]?.objectValue)
        #expect(counts.count == FileFormat.allCases.count)
        #expect(counts.values.compactMap(\.intValue).reduce(0, +) == SearchRequestLimits.maximumIndexedFiles)
        for (offset, format) in FileFormat.allCases.enumerated() {
            let expected = SearchRequestLimits.maximumIndexedFiles / FileFormat.allCases.count
                + (offset < SearchRequestLimits.maximumIndexedFiles % FileFormat.allCases.count ? 1 : 0)
            #expect(counts[format.rawValue] == .int(expected))
        }
        #expect(object["failed_files"] == .int(SearchRequestLimits.maximumIndexedFiles))
        #expect(object["samples_truncated"] == .bool(true))
        #expect(try JSONEncoder().encode(coverage).count <= DiscoveryCoverageAccumulator.maximumEncodedBytes)
    }

    @Test("Search-only format coverage has bounded schema and truthful narrowing guidance")
    func coverageSchemaAndGuidance() async throws {
        try await withRuntime { runtime, root in
            let search = try await discoveredTool(runtime: runtime, root: root, search: runtime.search)
            let coverage = try #require(search.outputSchema?.objectValue?["properties"]?.objectValue?["coverage"]?.objectValue)
            let counts = try #require(coverage["properties"]?.objectValue?["failed_by_format"]?.objectValue)
            #expect(counts["type"] == .string("object"))
            #expect(counts["maxProperties"] == .int(FileFormat.allCases.count))
            let completeFormats = try #require(coverage["properties"]?.objectValue?["complete_formats"]?.objectValue)
            #expect(completeFormats["maxItems"] == .int(FileFormat.allCases.count))
            #expect(completeFormats["uniqueItems"] == .bool(true))
            let description = search.description ?? ""
            #expect(description.contains("failed_by_format"))
            #expect(description.contains("narrowed scope"))
            #expect(description.contains("do not infer absence"))

            let links = LinkQueryToolDefinition.build()
            let linkCoverage = try #require(links.outputSchema?.objectValue?["properties"]?.objectValue?["coverage"]?.objectValue)
            #expect(linkCoverage["properties"]?.objectValue?["failed_by_format"] == nil)
            let existing = DiscoveryCoverage(complete: false, failedFiles: 1,
                samples: [.init(path: "notes/missing.md", reason: .unreadable)], samplesTruncated: false)
            let encoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(existing))
            #expect(encoded.objectValue?["failed_by_format"] == nil)
        }
    }


    @Test("Missing search directory is an actionable read-only scope failure")
    func missingDirectoryIsActionable() async throws {
        try await withRuntime { runtime, root in
            let result = try await SearchToolController(search: runtime.search).call(.init(
                name: "search_vault", arguments: [
                    "location": .string("notes"), "directory": .string("PRIVATE_ERROR_MARKER/missing"),
                    "query": .string("needle"),
                ]
            ))
            #expect(result.isError == true)
            let message = try firstText(result)
            #expect(message.lowercased().contains("directory not found"))
            #expect(!message.contains("Unexpected"))
            #expect(!message.contains("PRIVATE_ERROR_MARKER"))
            #expect(!message.contains(root.path))
            let error = try #require(result.structuredContent?.objectValue?["error"]?.objectValue)
            #expect(error["code"] == .string("DIRECTORY_NOT_FOUND"))
            #expect(error["state"] == .string("read_only"))
            #expect(error["retry"] == .string("correct_request"))
        }
    }


    @Test("Metadata-filtered partial search never certifies unsearched formats")
    func partialMetadataSearchCertifiesOnlyEligibleFormats() async throws {
        try await withRuntime { runtime, root in
            try Data([0xff]).write(to: root.appendingPathComponent("notes/invalid.md"))
            try Data("{}".utf8).write(to: root.appendingPathComponent("notes/healthy.json"))
            let result = try await SearchToolController(search: runtime.search).call(.init(
                name: "search_vault", arguments: [
                    "location": .string("notes"), "tags": .array([.string("qa")]),
                ]
            ))
            try #require(result.isError != true)
            let coverage = try #require(result.structuredContent?.objectValue?["coverage"]?.objectValue)
            #expect(coverage["complete"] == .bool(false))
            #expect(coverage["failed_by_format"] == .object(["markdown": .int(1)]))
            #expect(coverage["complete_formats"] == .array([]))
        }
    }

    private func discoveredTool(runtime: VaultRuntime, root: URL, search: any VaultSearchService) async throws -> Tool {
        let transports = await InMemoryTransport.createConnectedPair()
        try await transports.server.connect()
        let server = Task {
            try await MCPServerSetup.start(
                config: ServerConfig(vaultPath: root.path, readOnly: true),
                files: runtime.files, paths: runtime.paths, search: search,
                links: runtime.links, listing: runtime.listing,
                capabilities: runtime.capabilities, transport: transports.server
            )
        }
        let client = Client(name: "SearchAcceptanceTests", version: "1")
        do {
            _ = try await client.connect(transport: transports.client)
            let tools = try await client.listTools().tools
            await client.disconnect()
            try await server.value
            return try #require(tools.first { $0.name == "search_vault" })
        } catch {
            await client.disconnect()
            server.cancel()
            _ = try? await server.value
            throw error
        }
    }

    private func formatNames(_ tool: Tool) throws -> Set<String> {
        let formats = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["formats"]?
            .objectValue?["items"]?.objectValue?["enum"]?.arrayValue)
        return Set(formats.compactMap(\.stringValue))
    }

    private func firstText(_ result: CallTool.Result) throws -> String {
        guard case .text(let text, _, _) = result.content.first else { throw MissingText() }
        return text
    }

    private func withRuntime(_ operation: (VaultRuntime, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchAcceptanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("references"), withIntermediateDirectories: true)
        let support = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            removeSearchFixture(root)
            try? FileManager.default.removeItem(at: support.rootURL)
        }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root.path, readOnly: true)
        try await operation(runtime, root)
    }

    private struct SyntheticImageProvider: SearchAtomProvider {
        func atoms(for target: ReadableFileTarget, snapshot: FileSnapshot) async throws -> [SearchAtom] {
            [.init(locator: .init(path: target.relativePath, format: target.format), text: "needle", metadata: nil)]
        }
    }

    private struct AllFormatsFailureSource: VaultSearchAtomSource {
        let searchableFormats = FileFormat.allCases
        func scan(_ request: VaultSearchRequest, consume: @escaping @Sendable (SearchDocument) async throws -> Void) async throws -> Set<FileFormat> {
            for index in 0..<SearchRequestLimits.maximumIndexedFiles {
                try await consume(SearchDocument(
                    path: "notes/" + (index == 0 ? String(repeating: "x", count: 1_850)
                        : String(repeating: "🧠", count: 600)) + "\(index)",
                    format: FileFormat.allCases[index % FileFormat.allCases.count],
                    revision: nil, atoms: [], failure: .fileLimit
                ))
            }
            return Set(searchableFormats)
        }
    }

    private struct MissingText: Error {}
}
