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
            "location", "query", "tags", "created_from", "created_through", "limit", "cursor",
        ]))
        #expect(inputProperties["location"]?.objectValue?["enum"]?.arrayValue?
            .compactMap(\.stringValue) == VaultArea.allCases.map(\.rawValue))

        let output = try #require(tool.outputSchema?.objectValue)
        let outputProperties = try #require(output["properties"]?.objectValue)
        let outputRequired = try #require(output["required"]?.arrayValue).compactMap(\.stringValue)
        #expect(outputRequired == ["results"])
        #expect(Set(outputProperties.keys) == Set(["results", "next_cursor"]))
        let resultProperties = try #require(
            outputProperties["results"]?.objectValue?["items"]?
                .objectValue?["properties"]?.objectValue
        )
        #expect(Set(resultProperties.keys) == Set(["path", "format", "page"]))
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
            ])
        }
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
        #expect(Set(values.keys) == Set(["results"]))
        let item = try #require(values["results"]?.arrayValue?.first?.objectValue)
        #expect(Set(item.keys) == Set(["path", "format", "page"]))
        #expect(item["page"]?.intValue == 3)
    }
}
