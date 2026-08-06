import Testing
@testable import SecondBrainMCP

@Suite("Canonical path containment")
struct CanonicalPathContainmentTests {
    @Test("Accepts the exact root and separator-delimited descendants")
    func acceptsContainedPaths() {
        #expect(CanonicalPathContainment.contains(path: "/vault", within: "/vault"))
        #expect(CanonicalPathContainment.contains(path: "/vault/note.md", within: "/vault"))
        #expect(CanonicalPathContainment.contains(path: "/vault/deep/note.md", within: "/vault"))
    }

    @Test("Rejects siblings that only share the root prefix")
    func rejectsLookalikePrefixes() {
        #expect(!CanonicalPathContainment.contains(path: "/vault-copy", within: "/vault"))
        #expect(!CanonicalPathContainment.contains(path: "/vault-copy/note.md", within: "/vault"))
        #expect(!CanonicalPathContainment.contains(path: "/other/vault", within: "/vault"))
    }

    @Test("Normalizes trailing root separators")
    func normalizesTrailingSeparators() {
        #expect(CanonicalPathContainment.contains(path: "/vault", within: "/vault///"))
        #expect(CanonicalPathContainment.contains(path: "/vault/note.md", within: "/vault///"))
        #expect(!CanonicalPathContainment.contains(path: "/vault-copy", within: "/vault///"))
    }

    @Test("Filesystem root contains every absolute path but no relative path")
    func handlesFilesystemRoot() {
        #expect(CanonicalPathContainment.contains(path: "/", within: "/"))
        #expect(CanonicalPathContainment.contains(path: "/tmp/file", within: "/"))
        #expect(!CanonicalPathContainment.contains(path: "tmp/file", within: "/"))
    }
}
