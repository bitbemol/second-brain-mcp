import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("Media source parameter diagnostics")
struct MediaSourceParameterTests {
    @Test("Wire data URI sources explain the external-file contract without echoing payloads")
    func wireDataURISourceIsActionable() throws {
        let source = "data:image/png;base64," + Data("PRIVATE_SOURCE_PAYLOAD".utf8).base64EncodedString()
        let encoded = try JSONSerialization.data(withJSONObject: [
            "name": "create_file",
            "arguments": ["format": "png", "path": "notes/test.png", "source": source],
        ])
        let params = try JSONDecoder().decode(CallTool.Parameters.self, from: encoded)
        expectSourceRejection(params, forbidden: [source, "PRIVATE_SOURCE_PAYLOAD"])
    }

    @Test("Unsupported data URI sources are rejected consistently for directly constructed calls",
          arguments: ["data:image/png;base64,eA==", "data:text/plain,PRIVATE_SOURCE_PAYLOAD", "DATA:image/png;base64,eA=="])
    func directDataURISourceIsActionable(_ source: String) {
        expectSourceRejection(.init(name: "create_file", arguments: [
            "format": .string("png"), "path": .string("notes/test.png"), "source": .string(source),
        ]), forbidden: [source, "PRIVATE_SOURCE_PAYLOAD"])
    }

    @Test("A real wrong JSON type keeps the accurate string-type diagnostic",
          arguments: [Value.int(4), .bool(true), .null, .array([]), .object([:])])
    func nonStringSourceIsStillRejected(_ source: Value) {
        do {
            _ = try FileToolRequestDecoder.decode(.init(name: "create_file", arguments: [
                "format": .string("png"), "path": .string("notes/test.png"), "source": source,
            ]), for: .create)
            Issue.record("Non-string source must not be accepted")
        } catch let error as FileToolRequestDecoder.DecodingError {
            #expect(error.description == "Invalid parameter 'source': expected string")
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("External file paths retain their exact spelling at ingress")
    func externalPathIsNotRewritten() throws {
        let source = "/tmp/external fixture.png"
        let encoded = try JSONSerialization.data(withJSONObject: [
            "name": "create_file",
            "arguments": ["format": "png", "path": "notes/test.png", "source": source],
        ])
        let params = try JSONDecoder().decode(CallTool.Parameters.self, from: encoded)
        guard case .create(let request) = try FileToolRequestDecoder.decode(params, for: .create) else {
            Issue.record("Expected create request")
            return
        }
        #expect(request.source == source)
    }

    private func expectSourceRejection(_ params: CallTool.Parameters, forbidden: [String]) {
        do {
            _ = try FileToolRequestDecoder.decode(params, for: .create)
            Issue.record("Data URIs are not external source file paths")
        } catch let error as FileToolRequestDecoder.DecodingError {
            let message = error.description
            #expect(message.contains("source"))
            #expect(message.contains("external"))
            #expect(message.contains("path"))
            #expect(message.contains("outside the vault"))
            #expect(message.contains("data URI"))
            #expect(!message.contains("expected string"))
            #expect(message.utf8.count <= 1_024)
            for value in forbidden { #expect(!message.contains(value)) }
        } catch {
            Issue.record("Unexpected error type")
        }
    }
}
