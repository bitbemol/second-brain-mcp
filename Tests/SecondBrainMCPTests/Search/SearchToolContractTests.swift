import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `MCP vault search contract` {
    @Test
    func `Schema exposes only location filters pagination and atomic locators`() throws {
        let tool = SearchToolDefinition.build()
        let input = try #require(tool.inputSchema.objectValue)
        let inputProperties = try #require(input["properties"]?.objectValue)
        let required = try #require(input["required"]?.arrayValue).compactMap(\.stringValue)
        #expect(required == ["location"])
        #expect(Set(inputProperties.keys) == Set([
            "location", "directory", "formats", "query", "tags", "created_from", "created_through", "limit", "cursor",
        ]))
        #expect(inputProperties["location"]?.objectValue?["enum"]?.arrayValue?
            .compactMap(\.stringValue) == VaultArea.allCases.map(\.rawValue))
        #expect(inputProperties["tags"]?.objectValue?["minItems"]?.intValue == 1)
        let criteria = try #require(input["anyOf"]?.arrayValue)
        let criterionRequirements = Set(criteria.compactMap { criterion -> String? in
            criterion.objectValue?["required"]?.arrayValue?.first?.stringValue
        })
        #expect(criterionRequirements == [
            "query", "tags", "created_from", "created_through",
        ])

        let output = try #require(tool.outputSchema?.objectValue)
        let outputProperties = try #require(output["properties"]?.objectValue)
        let outputRequired = try #require(output["required"]?.arrayValue).compactMap(\.stringValue)
        #expect(outputRequired == ["results", "coverage"])
        #expect(Set(outputProperties.keys) == Set(["results", "next_cursor", "coverage"]))
        let resultProperties = try #require(
            outputProperties["results"]?.objectValue?["items"]?
                .objectValue?["properties"]?.objectValue
        )
        #expect(Set(resultProperties.keys) == Set([
            "path", "format", "page", "canvas_node_id", "canvas_field",
        ]))
    }

    @Test
    func `Discovery schemas explain selection pagination and every locator field`() throws {
        let search = SearchToolDefinition.build()
        #expect(search.description?.contains("JSON Canvas node") == true)
        #expect(search.description?.contains("PDF OCR may miss words even with complete coverage") == true)
        let searchInput = try schemaProperties(search.inputSchema)
        let searchOutput = try schemaProperties(try #require(search.outputSchema))
        let searchResults = try itemProperties(searchOutput, key: "results")
        #expect(describedKeys(searchInput) == Set(searchInput.keys))
        #expect(describedKeys(searchOutput) == Set(searchOutput.keys))
        #expect(describedKeys(searchResults) == Set(searchResults.keys))

        let links = LinkQueryToolDefinition.build()
        let linkInput = try schemaProperties(links.inputSchema)
        let linkOutput = try schemaProperties(try #require(links.outputSchema))
        let linkResults = try itemProperties(linkOutput, key: "results")
        #expect(describedKeys(linkInput) == Set(linkInput.keys))
        #expect(describedKeys(linkOutput) == Set(linkOutput.keys))
        #expect(describedKeys(linkResults) == Set(linkResults.keys))

        let listing = ListFilesToolDefinition.build(capabilities: FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes, .references]]),
        ]))
        let listingInput = try schemaProperties(listing.inputSchema)
        let listingOutput = try schemaProperties(try #require(listing.outputSchema))
        let listedFiles = try itemProperties(listingOutput, key: "files")
        #expect(describedKeys(listingInput) == Set(listingInput.keys))
        #expect(describedKeys(listingOutput) == Set(listingOutput.keys))
        #expect(describedKeys(listedFiles) == Set(listedFiles.keys))
    }

    @Test
    func `Decoder reuses VaultArea and preserves metadata filters`() throws {
        let request = try SearchToolRequestDecoder.decode(.init(
            name: "search_vault",
            arguments: [
                "location": .string("notes"),
                "tags": .array([.string("Swift"), .string("Architecture")]),
                "created_from": .string("2026-01-01"),
                "limit": .int(7),
            ]
        ))
        #expect(request.location == .notes)
        #expect(request.tags == ["Swift", "Architecture"])
        #expect(request.createdFrom == "2026-01-01")
        #expect(request.limit == 7)
        #expect(request.query == nil)
    }

    private actor SearchSpy: VaultSearchService {
        func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse {
            VaultSearchResponse(results: [
                VaultSearchResult(path: "references/book.pdf", format: .pdf, page: 3),
                VaultSearchResult(
                    path: "notes/board.canvas",
                    format: .canvas,
                    canvasNodeID: "node-1",
                    canvasField: "text"
                ),
            ])
        }
    }

    private actor FailingSearch: VaultSearchService {
        func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse {
            throw PathValidationError.pathChangedSinceValidation("notes/changed.md")
        }
    }

    @Test
    func `Controller returns actionable safe search failures`() async throws {
        let result = try await SearchToolController(search: FailingSearch()).call(.init(
            name: "search_vault",
            arguments: [
                "location": .string("notes"),
                "query": .string("actors"),
            ]
        ))

        #expect(result.isError == true)
        guard case .text(let message, _, _) = result.content.first else {
            Issue.record("Expected a diagnostic text block")
            return
        }
        #expect(message.contains("notes/"))
        #expect(message.contains("notes/changed.md"))
        #expect(!message.contains("failed safely"))
    }

    @Test
    func `Controller returns locators without content`() async throws {
        let result = try await SearchToolController(search: SearchSpy()).call(.init(
            name: "search_vault",
            arguments: [
                "location": .string("references"),
                "query": .string("actors"),
            ]
        ))
        let values = try #require(result.structuredContent?.objectValue)
        #expect(Set(values.keys) == Set(["results", "coverage"]))
        let item = try #require(values["results"]?.arrayValue?.first?.objectValue)
        #expect(Set(item.keys) == Set(["path", "format", "page"]))
        #expect(item["page"]?.intValue == 3)
        let canvas = try #require(values["results"]?.arrayValue?.last?.objectValue)
        #expect(canvas["canvas_node_id"]?.stringValue == "node-1")
        #expect(canvas["canvas_field"]?.stringValue == "text")
        #expect(!canvas.keys.contains("content"))
    }

    @Test
    func `Link query schema is bounded locator only and strict`() throws {
        let tool = LinkQueryToolDefinition.build()
        #expect(tool.name == "query_links")
        let input = try #require(tool.inputSchema.objectValue)
        let properties = try #require(input["properties"]?.objectValue)
        #expect(Set(properties.keys) == Set([
            "direction", "target", "from_path", "group_by", "source_path", "limit", "cursor",
        ]))
        #expect(input["required"]?.arrayValue?.compactMap(\.stringValue)
            == ["direction", "target"])
        #expect(input["additionalProperties"]?.boolValue == false)

        let output = try #require(tool.outputSchema?.objectValue)
        let outputProperties = try #require(output["properties"]?.objectValue)
        #expect(Set(outputProperties.keys) == Set([
            "direction", "results", "next_cursor", "coverage",
        ]))
        let itemProperties = try #require(
            outputProperties["results"]?.objectValue?["items"]?
                .objectValue?["properties"]?.objectValue
        )
        #expect(Set(itemProperties.keys) == Set([
            "source_path", "target", "resolved_path", "resolved_format", "kind",
            "alias", "fragment", "occurrence", "occurrence_count", "ambiguous",
        ]))
        #expect(!itemProperties.keys.contains("content"))
        #expect(!itemProperties.keys.contains("snippet"))
    }

    private actor LinkSpy: VaultLinkQueryService {
        private var request: LinkQueryRequest?

        func query(_ request: LinkQueryRequest) async throws -> LinkQueryResponse {
            self.request = request
            return LinkQueryResponse(
                direction: request.direction,
                results: [
                    LinkQueryResult(
                        sourcePath: "notes/source.md",
                        target: "Target",
                        resolvedPath: "notes/Target.md",
                        kind: .embed,
                        alias: "preview",
                        occurrence: 2,
                        ambiguous: false,
                        resolvedFormat: .markdown
                    ),
                ],
                nextCursor: "continue"
            )
        }

        func observed() -> LinkQueryRequest? {
            request
        }
    }

    @Test
    func `Link query controller decodes and maps structured locators only`() async throws {
        let spy = LinkSpy()
        let result = try await LinkQueryToolController(links: spy).call(.init(
            name: "query_links",
            arguments: [
                "direction": .string("outgoing"),
                "target": .string("notes/source.md"),
                "from_path": .string("notes/context.md"),
                "limit": .int(7),
                "cursor": .string("opaque"),
            ]
        ))

        let request = try #require(await spy.observed())
        #expect(request.direction == .outgoing)
        #expect(request.target == "notes/source.md")
        #expect(request.fromPath == "notes/context.md")
        #expect(request.limit == 7)
        #expect(request.cursor == "opaque")

        let values = try #require(result.structuredContent?.objectValue)
        #expect(Set(values.keys) == Set(["direction", "results", "next_cursor", "coverage"]))
        #expect(values["direction"]?.stringValue == "outgoing")
        let item = try #require(values["results"]?.arrayValue?.first?.objectValue)
        #expect(Set(item.keys) == Set([
            "source_path", "target", "resolved_path", "resolved_format", "kind",
            "alias", "occurrence", "ambiguous",
        ]))
        #expect(item["kind"]?.stringValue == "embed")
        #expect(item["occurrence"]?.intValue == 2)
        #expect(!item.keys.contains("content"))
        #expect(!item.keys.contains("snippet"))
    }

    private func schemaProperties(_ schema: MCP.Value) throws -> [String: MCP.Value] {
        let object = try #require(schema.objectValue)
        return try #require(object["properties"]?.objectValue)
    }

    private func itemProperties(
        _ properties: [String: MCP.Value],
        key: String
    ) throws -> [String: MCP.Value] {
        try #require(
            properties[key]?.objectValue?["items"]?
                .objectValue?["properties"]?.objectValue
        )
    }

    private func describedKeys(_ properties: [String: MCP.Value]) -> Set<String> {
        Set(properties.compactMap { key, value in
            guard let description = value.objectValue?["description"]?.stringValue,
                  !description.isEmpty else {
                return nil
            }
            return key
        })
    }
}
