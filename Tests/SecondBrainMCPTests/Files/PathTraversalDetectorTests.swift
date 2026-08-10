import Testing
@testable import second_brain_mcp

@Suite
struct `Path traversal detection` {
    @Test
    func `Detects plain and whitespace-obscured parent components`() {
        #expect(PathTraversalDetector.containsTraversal(in: "../secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "notes/../../secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "notes/  ..  /secret"))
    }

    @Test
    func `Detects single and nested percent encoding`() {
        #expect(PathTraversalDetector.containsTraversal(in: "%2e%2e/secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "%252e%252e/secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "%25252e%25252e/secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "%2e%2e%2fsecret"))
    }

    @Test
    func `Accepts safe dotted names and ordinary relative paths`() {
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/project..backup/file.md"))
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/.hidden/file.md"))
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/v1.2/file.md"))
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/%2Ehidden/file.md"))
    }

    @Test
    func `Malformed percent escapes remain literal path text`() {
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/%ZZ/file.md"))
    }
}
