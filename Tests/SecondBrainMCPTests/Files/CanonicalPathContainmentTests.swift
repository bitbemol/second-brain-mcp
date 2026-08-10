import Testing
@testable import second_brain_mcp

@Suite
struct `Canonical path containment` {
    @Test
    func `Accepts the exact root and separator-delimited descendants`() {
        #expect(CanonicalPathContainment.contains(path: "/vault", within: "/vault"))
        #expect(CanonicalPathContainment.contains(path: "/vault/note.md", within: "/vault"))
        #expect(CanonicalPathContainment.contains(path: "/vault/deep/note.md", within: "/vault"))
    }

    @Test
    func `Rejects siblings that only share the root prefix`() {
        #expect(!CanonicalPathContainment.contains(path: "/vault-copy", within: "/vault"))
        #expect(!CanonicalPathContainment.contains(path: "/vault-copy/note.md", within: "/vault"))
        #expect(!CanonicalPathContainment.contains(path: "/other/vault", within: "/vault"))
    }

    @Test
    func `Normalizes trailing root separators`() {
        #expect(CanonicalPathContainment.contains(path: "/vault", within: "/vault///"))
        #expect(CanonicalPathContainment.contains(path: "/vault/note.md", within: "/vault///"))
        #expect(!CanonicalPathContainment.contains(path: "/vault-copy", within: "/vault///"))
    }

    @Test
    func `Filesystem root contains every absolute path but no relative path`() {
        #expect(CanonicalPathContainment.contains(path: "/", within: "/"))
        #expect(CanonicalPathContainment.contains(path: "/tmp/file", within: "/"))
        #expect(!CanonicalPathContainment.contains(path: "tmp/file", within: "/"))
    }
}
