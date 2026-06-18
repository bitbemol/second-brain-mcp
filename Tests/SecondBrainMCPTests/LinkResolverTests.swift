import Testing
import Foundation
@testable import SecondBrainMCP

// MARK: - Link extraction (pure)

@Suite("LinkResolver — extraction")
struct LinkExtractionTests {

    @Test("Extracts embeds, links, aliases, subpaths; skips external URLs")
    func extract() {
        let content = """
        Embed ![[img.png]] and a link [[Some Note#Heading|Alias]],
        a relative md link [doc](path/to/file.md), an md embed ![pic](a/b.png),
        and an external [site](https://example.com) that must be skipped.
        """
        let links = LinkResolver.extractLinks(from: content)

        #expect(links.count == 4)
        #expect(links.contains { $0.target == "img.png" && $0.isEmbed })

        let note = try? #require(links.first { $0.target == "Some Note" })
        #expect(note?.subpath == "#Heading")
        #expect(note?.alias == "Alias")
        #expect(note?.isEmbed == false)

        #expect(links.contains { $0.target == "path/to/file.md" && !$0.isEmbed })
        #expect(links.contains { $0.target == "a/b.png" && $0.isEmbed && $0.alias == "pic" })
        #expect(!links.contains { $0.target.contains("example.com") })
    }

    @Test("parseSingle handles bare, bracketed, and embed forms")
    func parseSingle() {
        #expect(LinkResolver.parseSingle("![[a.png|alt]]").target == "a.png")
        #expect(LinkResolver.parseSingle("![[a.png|alt]]").isEmbed)
        #expect(LinkResolver.parseSingle("[[Note#H]]").target == "Note")
        #expect(LinkResolver.parseSingle("[[Note#H]]").subpath == "#H")
        #expect(LinkResolver.parseSingle("bare.png").target == "bare.png")
        #expect(!LinkResolver.parseSingle("bare.png").isEmbed)
    }
}

// MARK: - Resolution + backlinks (disk)

@Suite("LinkResolver — resolve & backlinks")
struct LinkResolverTests {

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "LinkResolver-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return root
    }

    private func write(_ content: String, _ rel: String, in root: String) throws {
        let full = root + "/" + rel
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: full, atomically: true, encoding: .utf8)
    }

    @Test("Bare basename resolves vault-wide, across folders (the Obsidian case)")
    func basenameVaultWide() throws {
        let root = try makeVault()
        try write("![[screenshot.png]]", "notes/apple/uikit/foo.md", in: root)
        try write("img", "notes/apple/_attachments/screenshot.png", in: root)

        let r = try LinkResolver(vaultPath: root).resolve(link: "screenshot.png", from: "notes/apple/uikit/foo.md")
        #expect(r.matches == ["notes/apple/_attachments/screenshot.png"])

        // The embed flag is carried when the link is written as an embed.
        let embed = try LinkResolver(vaultPath: root).resolve(link: "![[screenshot.png]]")
        #expect(embed.isEmbed)
        #expect(embed.matches == ["notes/apple/_attachments/screenshot.png"])
    }

    @Test("Extension-less target resolves to a .md note")
    func extensionlessIsNote() throws {
        let root = try makeVault()
        try write("# Target", "notes/projects/Target Note.md", in: root)
        let r = try LinkResolver(vaultPath: root).resolve(link: "[[Target Note]]")
        #expect(r.matches == ["notes/projects/Target Note.md"])
    }

    @Test("Ambiguous basename returns all candidates, nearest to `from` first")
    func ambiguityByProximity() throws {
        let root = try makeVault()
        try write("img", "notes/a/_attachments/dup.png", in: root)
        try write("img", "notes/b/_attachments/dup.png", in: root)
        let resolver = LinkResolver(vaultPath: root)

        let fromA = try resolver.resolve(link: "dup.png", from: "notes/a/x.md")
        #expect(fromA.matches.count == 2)
        #expect(fromA.matches.first == "notes/a/_attachments/dup.png")

        let fromB = try resolver.resolve(link: "dup.png", from: "notes/b/x.md")
        #expect(fromB.matches.first == "notes/b/_attachments/dup.png")
    }

    @Test("Path-qualified target resolves by path, not just basename")
    func pathQualified() throws {
        let root = try makeVault()
        try write("img", "notes/x/_attachments/p.png", in: root)
        try write("img", "notes/y/_attachments/p.png", in: root)
        let r = try LinkResolver(vaultPath: root).resolve(link: "y/_attachments/p.png")
        #expect(r.matches == ["notes/y/_attachments/p.png"])
    }

    @Test("Unresolvable target returns no matches")
    func noMatch() throws {
        let root = try makeVault()
        try write("hi", "notes/a.md", in: root)
        #expect(try LinkResolver(vaultPath: root).resolve(link: "nope.png").matches.isEmpty)
    }

    @Test("Backlinks find notes that embed a non-md file")
    func backlinksToImage() throws {
        let root = try makeVault()
        try write("uses ![[hero.png]] here", "notes/p/one.md", in: root)
        try write("also ![[hero.png]]", "notes/q/two.md", in: root)
        try write("different ![[other.png]]", "notes/p/three.md", in: root)
        try write("img", "notes/assets/hero.png", in: root)
        try write("img", "notes/assets/other.png", in: root)

        let b = try LinkResolver(vaultPath: root).backlinks(to: "notes/assets/hero.png")
        #expect(b.map(\.notePath) == ["notes/p/one.md", "notes/q/two.md"])
        #expect(b.allSatisfy { $0.isEmbed })
    }

    @Test("Backlinks disambiguate same-basename files by resolution")
    func backlinksDisambiguate() throws {
        let root = try makeVault()
        try write("img", "notes/x/_attachments/dup.png", in: root)
        try write("img", "notes/y/_attachments/dup.png", in: root)
        try write("see ![[y/_attachments/dup.png]]", "notes/y/note.md", in: root)  // by path → y
        try write("see ![[dup.png]]", "notes/x/note.md", in: root)                  // bare, from x/ → x
        let resolver = LinkResolver(vaultPath: root)

        #expect(try resolver.backlinks(to: "notes/x/_attachments/dup.png").map(\.notePath) == ["notes/x/note.md"])
        #expect(try resolver.backlinks(to: "notes/y/_attachments/dup.png").map(\.notePath) == ["notes/y/note.md"])
    }

    @Test("Backlinks accept a bare basename target")
    func backlinksByBasename() throws {
        let root = try makeVault()
        try write("ref [[wanted]]", "notes/a.md", in: root)
        try write("# wanted", "notes/sub/wanted.md", in: root)
        let b = try LinkResolver(vaultPath: root).backlinks(to: "wanted.md")
        #expect(b.map(\.notePath) == ["notes/a.md"])
        #expect(b.first?.isEmbed == false)
    }
}
