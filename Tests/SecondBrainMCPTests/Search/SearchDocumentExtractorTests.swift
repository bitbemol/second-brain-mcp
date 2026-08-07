import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault search extraction")
struct SearchDocumentExtractorTests {
    @Test("Markdown extraction finds front matter and real sections")
    func markdownSections() throws {
        let markdown = """
        ---
        title: "Concurrency Guide"
        tags: [swift, actors]
        ---
        Intro text.

        # Safe Writes
        Actor-isolated mutations.

        ```swift
        # not a heading
        ```

        ## Conflicts
        Read before updating.
        """
        let extracted = try SearchDocumentExtractor.extract(
            data: Data(markdown.utf8),
            path: "notes/concurrency.md",
            format: .markdown,
            maximumSections: 20
        )

        #expect(extracted.document.title == "Concurrency Guide")
        #expect(extracted.document.tags == ["swift", "actors"])
        #expect(extracted.document.sections.compactMap(\.heading) == [
            "Safe Writes", "Conflicts",
        ])
        #expect(extracted.document.sections.contains {
            $0.content.contains("# not a heading")
        })
    }

    @Test("HAR extraction sanitizes before content can influence search")
    func harSanitization() throws {
        let secret = "Bearer " + String(repeating: "s", count: 32)
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[
          {"request":{"method":"GET","url":"https://example.com",
           "headers":[{"name":"Authorization","value":"\(secret)"}]},
           "response":{"status":200},"time":1}
        ]}}
        """
        let extracted = try SearchDocumentExtractor.extract(
            data: Data(archive.utf8),
            path: "notes/capture.har",
            format: .har,
            maximumSections: 10
        )
        let content = try #require(extracted.document.sections.first?.content)
        #expect(!content.contains(secret))
        #expect(content.contains(HARSensitiveDataSanitizer.redactionMarker))
    }

    @Test("Section extraction is explicitly bounded")
    func sectionLimit() throws {
        let markdown = (1...20).map { "# Heading \($0)\nbody" }
            .joined(separator: "\n")
        let extracted = try SearchDocumentExtractor.extract(
            data: Data(markdown.utf8),
            path: "notes/many.md",
            format: .markdown,
            maximumSections: 3
        )
        #expect(extracted.document.sections.count == 3)
        #expect(extracted.truncated)
    }

    @Test("Generated and common front matter decode into real metadata")
    func frontMatterDecoding() throws {
        let generated = MarkdownSupport.generateFrontmatter(
            title: "A \"quoted\" title",
            tags: ["swift,actors", "json"]
        ) + "# Body\ntext"
        let decoded = try SearchDocumentExtractor.extract(
            data: Data(generated.utf8),
            path: "notes/generated.md",
            format: .markdown,
            maximumSections: 20
        )
        #expect(decoded.document.title == "A \"quoted\" title")
        #expect(decoded.document.tags == ["swift,actors", "json"])

        let blockList = """
        ---
        tags:
          - Swift
          - Actors
        ---
        # Actual Title
        body
        """
        let common = try SearchDocumentExtractor.extract(
            data: Data(blockList.utf8),
            path: "notes/common.md",
            format: .markdown,
            maximumSections: 20
        )
        #expect(common.document.tags == ["Swift", "Actors"])
        #expect(common.document.title == "Actual Title")
    }

    @Test("Line, tag, and metadata byte ceilings report incomplete coverage")
    func objectAmplificationLimits() throws {
        let markdown = """
        ---
        title: "a\(String(repeating: "\u{301}", count: 2_000))"
        tags: [one, two, three, four, five]
        ---
        first
        second
        third
        fourth
        fifth
        """
        let extracted = try SearchDocumentExtractor.extract(
            data: Data(markdown.utf8),
            path: "notes/bounded.md",
            format: .markdown,
            maximumSections: 10,
            maximumMarkdownLines: 7,
            maximumFrontMatterLines: 10,
            maximumTags: 2,
            maximumAggregateTagBytes: 6,
            maximumMetadataCharacters: 512,
            maximumMetadataBytes: 16
        )

        #expect(extracted.truncated)
        #expect(extracted.document.tags.count <= 2)
        #expect(extracted.document.tags.map(\.utf8.count).reduce(0, +) <= 6)
        #expect(extracted.document.title.utf8.count <= 16)
        #expect(extracted.document.sections.count <= 10)
    }

    @Test("Canvas projects searchable node values without raw JSON noise")
    func canvasProjection() throws {
        let canvas = """
        {"nodes":[
          {"id":"text-1","type":"text","x":9999,"y":0,"width":1,"height":1,"text":"Needle body"},
          {"id":"group-1","type":"group","x":0,"y":0,"width":1,"height":1,"label":"Roadmap"}
        ],"edges":[]}
        """
        let extracted = try SearchDocumentExtractor.extract(
            data: Data(canvas.utf8),
            path: "notes/plan.canvas",
            format: .canvas,
            maximumSections: 10
        )

        #expect(extracted.document.sections.map(\.content) == [
            "Needle body", "Roadmap",
        ])
        #expect(extracted.document.sections.first?.location == VaultSearchLocation(
            nodeID: "text-1",
            nodeType: "text",
            field: "text"
        ))
        #expect(!extracted.document.sections.contains { $0.content.contains("9999") })
    }
}
