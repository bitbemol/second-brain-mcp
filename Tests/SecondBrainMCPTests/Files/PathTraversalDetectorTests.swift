import Testing
@testable import SecondBrainMCP

@Suite("Path traversal detection")
struct PathTraversalDetectorTests {
    @Test("Detects plain and whitespace-obscured parent components")
    func detectsParentComponents() {
        #expect(PathTraversalDetector.containsTraversal(in: "../secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "notes/../../secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "notes/  ..  /secret"))
    }

    @Test("Detects single and nested percent encoding")
    func detectsPercentEncodedTraversal() {
        #expect(PathTraversalDetector.containsTraversal(in: "%2e%2e/secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "%252e%252e/secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "%25252e%25252e/secret"))
        #expect(PathTraversalDetector.containsTraversal(in: "%2e%2e%2fsecret"))
    }

    @Test("Accepts safe dotted names and ordinary relative paths")
    func acceptsSafePaths() {
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/project..backup/file.md"))
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/.hidden/file.md"))
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/v1.2/file.md"))
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/%2Ehidden/file.md"))
    }

    @Test("Malformed percent escapes remain literal path text")
    func acceptsMalformedPercentEscapes() {
        #expect(!PathTraversalDetector.containsTraversal(in: "notes/%ZZ/file.md"))
    }
}
