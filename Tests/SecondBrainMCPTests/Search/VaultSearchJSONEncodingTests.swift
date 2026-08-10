import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Vault search JSON encoding")
struct VaultSearchJSONEncodingTests {
    @Test("Canonical response text and byte sizing are identical")
    func responseEquivalence() throws {
        let response = fixtureResponse()
        let data = try VaultSearchJSONEncoding.responseData(response)
        let text = try VaultSearchJSONEncoding.responseText(response)

        #expect(Data(text.utf8) == data)
        #expect(try VaultSearchJSONEncoding.responseByteCount(response) == data.count)
        #expect(text.contains("\"line_start\""))
        #expect(text.contains("https://example.com/reference"))
        #expect(!text.contains("https:\\/\\/example.com"))
    }

    @Test("Canonical result admission size uses the encoded result array")
    func resultBudgetEquivalence() throws {
        let results = fixtureResponse().results
        let data = try VaultSearchJSONEncoding.resultsData(results)

        #expect(try VaultSearchJSONEncoding.resultsByteCount(results) == data.count)
        #expect(!data.contains(0x0A))
        #expect(String(decoding: data, as: UTF8.self).contains("\"matched_fields\""))
    }

    private func fixtureResponse() -> VaultSearchResponse {
        VaultSearchResponse(
            strategy: .exact,
            results: [VaultSearchResult(
                path: "notes/reference.md",
                format: .markdown,
                title: "Reference",
                heading: nil,
                location: nil,
                snippet: "https://example.com/reference",
                lineStart: 2,
                lineEnd: 2,
                matchedFields: [.content],
                relevance: 1,
                termCoverage: 1,
                completeQueryFields: [.content]
            )],
            searchedFileCount: 1,
            skippedFileCount: 0,
            skippedSensitiveFileCount: 0,
            resourceLimitedFileCount: 0,
            moreResultsAvailable: false,
            coverageIncomplete: false
        )
    }
}
