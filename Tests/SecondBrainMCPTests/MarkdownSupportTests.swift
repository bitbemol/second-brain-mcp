import Testing
@testable import SecondBrainMCP

@Suite("Markdown support")
struct MarkdownSupportTests {
    @Test("Generates frontmatter with normalized tags")
    func frontmatterWithTags() {
        let result = MarkdownSupport.generateFrontmatter(
            title: "My Note",
            tags: ["Swift", " Architecture "],
            date: "2026-08-05"
        )

        #expect(result.contains("title: \"My Note\""))
        #expect(result.contains("created: 2026-08-05"))
        #expect(result.contains("tags: [\"swift\", \"architecture\"]"))
    }

    @Test("Omits empty tags")
    func frontmatterWithoutTags() {
        let result = MarkdownSupport.generateFrontmatter(
            title: "My Note",
            tags: ["  ", "\n"],
            date: "2026-08-05"
        )
        #expect(!result.contains("tags:"))
    }

    @Test("Escapes title and tag values onto their existing YAML lines")
    func frontmatterEscaping() {
        let result = MarkdownSupport.generateFrontmatter(
            title: "Roadmap\"\n---\nadmin: true",
            tags: ["Safe", "bad]\\\n---\nowned: true"],
            date: "2026-08-05"
        )
        let lines = result.components(separatedBy: "\n")

        #expect(lines.filter { $0 == "---" }.count == 2)
        #expect(lines[1] == "title: \"Roadmap\\\"\\u000A---\\u000Aadmin: true\"")
        #expect(lines[3] == "tags: [\"safe\", \"bad]\\\\\\u000A---\\u000Aowned: true\"]")
    }

    @Test("Derives a readable title from a filename")
    func filenameTitle() {
        #expect(MarkdownSupport.titleFromFilename("my_note-name.md") == "my note name")
    }

    @Test("Distinguishes front matter from a thematic break")
    func frontmatterDetection() {
        #expect(MarkdownSupport.hasFrontmatter("---\ntitle: Note\n---\nBody"))
        #expect(!MarkdownSupport.hasFrontmatter("---\n# Heading"))
        #expect(!MarkdownSupport.hasFrontmatter("Text\n---\nMore"))
    }
}
