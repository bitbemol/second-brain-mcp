import Testing
import Foundation
@testable import second_brain_mcp

// MARK: - Happy Path

@Suite
struct `PathValidator — Happy Path` {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/notes/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)
        // Create test files
        fm.createFile(atPath: root + "/notes/hello.md", contents: nil)
        fm.createFile(atPath: root + "/notes/projects/app.md", contents: nil)
        fm.createFile(atPath: root + "/references/book.pdf", contents: nil)
    }

    @Test
    func `Simple relative path resolves correctly`() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/hello.md", root: root)
        #expect(resolved.hasSuffix("/notes/hello.md"))
        #expect(resolved.hasPrefix(root))
    }

    @Test
    func `Nested relative path resolves correctly`() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/projects/app.md", root: root)
        #expect(resolved.hasSuffix("/notes/projects/app.md"))
    }

    @Test
    func `Path with allowed extension passes`() throws {
        let resolved = try PathValidator.resolve(
            relativePath: "notes/hello.md",
            root: root,
            allowedExtensions: ["md", "markdown"]
        )
        #expect(resolved.hasSuffix("/notes/hello.md"))
    }

    @Test
    func `PDF extension passes when allowed`() throws {
        let resolved = try PathValidator.resolve(
            relativePath: "references/book.pdf",
            root: root,
            allowedExtensions: ["pdf"]
        )
        #expect(resolved.hasSuffix("/references/book.pdf"))
    }

    @Test
    func `No extension filter means all extensions pass`() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/hello.md", root: root)
        #expect(resolved.hasSuffix("/notes/hello.md"))
    }
}

// MARK: - Traversal Attacks

@Suite
struct `PathValidator — Traversal Attacks` {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    }

    @Test
    func `Basic parent traversal is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "../etc/passwd", root: root)
        }
    }

    @Test
    func `Deep traversal is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "../../../../../../etc/passwd", root: root)
        }
    }

    @Test
    func `Traversal hidden in subdirectory is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "notes/../../etc/passwd", root: root)
        }
    }

    @Test
    func `Traversal at end of path is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "notes/..", root: root)
        }
    }

    @Test
    func `URL-encoded traversal is rejected (%2e%2e%2f)`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "%2e%2e%2fetc/passwd", root: root)
        }
    }

    @Test
    func `Double URL-encoded traversal is rejected (%252e%252e)`() {
        // The first pass produces %2e%2e; the second exposes the parent component.
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "%252e%252e/etc/passwd", root: root)
        }
    }

    @Test
    func `Mixed traversal with valid prefix is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "notes/projects/../../..", root: root)
        }
    }
}

// MARK: - Symlink Attacks

@Suite
struct `PathValidator — Symlink Attacks` {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    }

    @Test
    func `Symlink pointing outside vault is rejected`() throws {
        let fm = FileManager.default
        let symlinkPath = root + "/notes/evil-link"

        // Create a symlink inside the vault that points to /tmp
        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: "/tmp")

        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "notes/evil-link", root: root)
        }
    }

    @Test
    func `Symlink pointing within vault is allowed`() throws {
        let fm = FileManager.default
        // Create target
        try fm.createDirectory(atPath: root + "/notes/real-dir", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/notes/real-dir/note.md", contents: nil)

        // Create symlink within vault
        let symlinkPath = root + "/notes/link-to-real"
        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: root + "/notes/real-dir")

        let resolved = try PathValidator.resolve(relativePath: "notes/link-to-real/note.md", root: root)
        #expect(resolved.hasPrefix(root))
    }
}

// MARK: - Edge Cases

@Suite
struct `PathValidator — Edge Cases` {

    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "PathValidatorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
    }

    @Test
    func `Empty path is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "", root: root)
        }
    }

    @Test
    func `Absolute path is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(relativePath: "/etc/passwd", root: root)
        }
    }

    @Test
    func `Disallowed extension is rejected`() {
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(
                relativePath: "notes/secrets.env",
                root: root,
                allowedExtensions: ["md", "markdown"]
            )
        }
    }

    @Test
    func `Path with double slashes resolves safely`() throws {
        FileManager.default.createFile(atPath: root + "/notes/test.md", contents: nil)
        let resolved = try PathValidator.resolve(relativePath: "notes//test.md", root: root)
        #expect(resolved.hasPrefix(root))
    }

    @Test
    func `Path with trailing slash resolves safely`() throws {
        let resolved = try PathValidator.resolve(relativePath: "notes/", root: root)
        #expect(resolved.hasPrefix(root))
    }

    @Test
    func `Root prefix attack is prevented (vault-evil vs vault)`() throws {
        let fm = FileManager.default
        // Create a sibling directory that shares the root prefix
        let evilRoot = root + "-evil"
        try fm.createDirectory(atPath: evilRoot, withIntermediateDirectories: true)
        fm.createFile(atPath: evilRoot + "/stolen.md", contents: nil)

        // Attempt to access sibling via traversal — this must fail
        #expect(throws: PathValidationError.self) {
            try PathValidator.resolve(
                relativePath: "../" + (root as NSString).lastPathComponent + "-evil/stolen.md",
                root: root
            )
        }
    }

    @Test
    func `Path with spaces resolves correctly`() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/notes/my folder", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/notes/my folder/my note.md", contents: nil)

        let resolved = try PathValidator.resolve(relativePath: "notes/my folder/my note.md", root: root)
        #expect(resolved.contains("my folder"))
        #expect(resolved.hasPrefix(root))
    }

    @Test
    func `Case sensitivity is preserved`() throws {
        let fm = FileManager.default
        fm.createFile(atPath: root + "/notes/README.md", contents: nil)

        let resolved = try PathValidator.resolve(relativePath: "notes/README.md", root: root)
        #expect(resolved.hasSuffix("/notes/README.md"))
    }

    @Test
    func `Single dot path component is handled`() throws {
        FileManager.default.createFile(atPath: root + "/notes/test.md", contents: nil)
        let resolved = try PathValidator.resolve(relativePath: "./notes/test.md", root: root)
        #expect(resolved.hasPrefix(root))
        #expect(resolved.hasSuffix("/notes/test.md"))
    }
}
