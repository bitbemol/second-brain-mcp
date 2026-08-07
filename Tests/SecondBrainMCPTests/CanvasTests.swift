import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Canvas document validation")
struct CanvasDocumentValidatorTests {
    private func validate(_ json: String) throws {
        try CanvasDocumentValidator.validate(jsonData: Data(json.utf8))
    }

    @Test("Valid canvas with nodes and edges passes")
    func valid() throws {
        try validate("""
        {"nodes":[
          {"id":"a","type":"text","x":0,"y":0,"width":200,"height":60,"text":"Hello"},
          {"id":"b","type":"file","x":0,"y":100,"width":200,"height":60,"file":"notes/x.md","subpath":"#section"},
          {"id":"c","type":"link","x":0,"y":200,"width":200,"height":60,"url":"https://example.com"},
          {"id":"d","type":"group","x":0,"y":300,"width":400,"height":200,"label":"Group","backgroundStyle":"cover","color":"4"}
        ],
        "edges":[{"id":"e1","fromNode":"a","toNode":"b","fromSide":"bottom","toEnd":"arrow","color":"#FF0000"}]}
        """)
    }

    @Test("Inspection projects validated node presentation data")
    func inspection() throws {
        let result = try CanvasDocumentValidator.inspect(jsonData: Data("""
        {"nodes":[
          {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"First line\\nSecond line"},
          {"id":"b","type":"file","x":0,"y":0,"width":1,"height":1,"file":"notes/x.md"},
          {"id":"c","type":"link","x":0,"y":0,"width":1,"height":1,"url":"https://example.com"},
          {"id":"d","type":"group","x":0,"y":0,"width":1,"height":1,"label":"Group"}
        ],"edges":[{"id":"e","fromNode":"a","toNode":"b"}]}
        """.utf8))

        #expect(result.nodes.map(\.kind) == [.text, .file, .link, .group])
        #expect(result.nodes.map(\.label) == [
            "First line", "notes/x.md", "https://example.com", "Group"
        ])
        #expect(result.nodes[1].filePath == "notes/x.md")
        #expect(result.edgeCount == 1)
    }

    @Test("Empty canvas passes")
    func empty() throws {
        try validate("{}")
        try validate(#"{"nodes":[],"edges":[]}"#)
    }

    @Test("Malformed JSON is rejected")
    func malformed() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate("{not json")
        }
    }

    @Test("Duplicate JSON object keys are rejected before semantic decoding")
    func duplicateJSONKeys() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[],"n\u006fdes":[]}"#)
        }
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[{"id":"a","i\u0064":"b","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x"}]}"#)
        }
    }

    @Test("Duplicate node id is rejected")
    func duplicateID() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate("""
            {"nodes":[
              {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"one"},
              {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"two"}
            ]}
            """)
        }
    }

    @Test("Edge referencing a missing node is rejected")
    func danglingEdge() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate("""
            {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"hi"}],
             "edges":[{"id":"e","fromNode":"a","toNode":"ghost"}]}
            """)
        }
    }

    @Test("Unknown node type is rejected")
    func unknownType() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[{"id":"a","type":"sticky","x":0,"y":0,"width":1,"height":1}]}"#)
        }
    }

    @Test("Missing required geometry is rejected")
    func missingGeometry() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"text":"hi"}]}"#)
        }
    }

    @Test("Invalid enum values are rejected")
    func badEnums() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[{"id":"g","type":"group","x":0,"y":0,"width":1,"height":1,"backgroundStyle":"wrong"}]}"#)
        }
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate("""
            {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x"},
                      {"id":"b","type":"text","x":0,"y":0,"width":1,"height":1,"text":"y"}],
             "edges":[{"id":"e","fromNode":"a","toNode":"b","fromSide":"diagonal"}]}
            """)
        }
    }

    @Test("Invalid color is rejected")
    func badColor() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(##"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x","color":"#zz"}]}"##)
        }
    }

    @Test("Unknown extra keys are accepted")
    func extraKeysAccepted() throws {
        try validate("""
        {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x","pluginField":42}],
         "customTopLevel":{"foo":"bar"}}
        """)
    }
}
