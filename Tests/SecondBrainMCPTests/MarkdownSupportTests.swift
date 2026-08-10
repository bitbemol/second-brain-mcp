import Testing
@testable import second_brain_mcp

@Suite
struct `Markdown support` {
    @Test
    func `Generates frontmatter with normalized tags`() {
        let result = MarkdownSupport.generateFrontmatter(
            title: "My Note",
            tags: ["Swift", " Architecture "],
            date: "2026-08-05"
        )

        #expect(result.contains("title: \"My Note\""))
        #expect(result.contains("created: 2026-08-05"))
        #expect(result.contains("tags: [\"swift\", \"architecture\"]"))
    }

    @Test
    func `Omits empty tags`() {
        let result = MarkdownSupport.generateFrontmatter(
            title: "My Note",
            tags: ["  ", "\n"],
            date: "2026-08-05"
        )
        #expect(!result.contains("tags:"))
    }

    @Test
    func `Escapes title and tag values onto their existing YAML lines`() {
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

    @Test
    func `Derives a readable title from a filename`() {
        #expect(MarkdownSupport.titleFromFilename("my_note-name.md") == "my note name")
    }

    @Test
    func `Distinguishes front matter from a thematic break`() {
        #expect(MarkdownSupport.hasFrontmatter("---\ntitle: Note\n---\nBody"))
        #expect(!MarkdownSupport.hasFrontmatter("---\n# Heading"))
        #expect(!MarkdownSupport.hasFrontmatter("Text\n---\nMore"))
    }
}
