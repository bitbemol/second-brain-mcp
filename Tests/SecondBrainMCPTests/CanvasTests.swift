import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Canvas document validation` {
    private func validate(_ json: String) throws {
        try CanvasDocumentValidator.validate(jsonData: Data(json.utf8))
    }

    @Test
    func `Valid canvas with nodes and edges passes`() throws {
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

    @Test
    func `Empty canvas passes`() throws {
        try validate("{}")
        try validate(#"{"nodes":[],"edges":[]}"#)
    }

    @Test
    func `Malformed JSON is rejected`() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate("{not json")
        }
    }

    @Test
    func `Duplicate JSON object keys are rejected before semantic decoding`() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[],"n\u006fdes":[]}"#)
        }
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[{"id":"a","i\u0064":"b","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x"}]}"#)
        }
    }

    @Test
    func `Duplicate node id is rejected`() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate("""
            {"nodes":[
              {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"one"},
              {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"two"}
            ]}
            """)
        }
    }

    @Test
    func `Edge referencing a missing node is rejected`() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate("""
            {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"hi"}],
             "edges":[{"id":"e","fromNode":"a","toNode":"ghost"}]}
            """)
        }
    }

    @Test
    func `Unknown node type is rejected`() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[{"id":"a","type":"sticky","x":0,"y":0,"width":1,"height":1}]}"#)
        }
    }

    @Test
    func `Missing required geometry is rejected`() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(#"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"text":"hi"}]}"#)
        }
    }

    @Test
    func `Invalid enum values are rejected`() {
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

    @Test
    func `Invalid color is rejected`() {
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try validate(##"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x","color":"#zz"}]}"##)
        }
    }

    @Test
    func `Unknown extra keys are accepted`() throws {
        try validate("""
        {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x","pluginField":42}],
         "customTopLevel":{"foo":"bar"}}
        """)
    }
}
