import Foundation
import MCP
import Testing

/// SDK-only regressions: this file can be copied into the upstream MCPTests target.
@Suite("SDK JSON string fidelity")
struct SDKJSONStringFidelityTests {
    @Test("JSON strings preserve their type and exact UTF-8 bytes", arguments: [
        "ordinary 🧠 text",
        "data:text/plain,Hello%20World",
        "data:,Hello%20World",
        "data:text/plain;base64,SGVsbG8gV29ybGQ=",
    ])
    func stringRoundTrip(_ original: String) throws {
        let input = try JSONEncoder().encode(original)
        let value = try JSONDecoder().decode(Value.self, from: input)

        #expect(value == .string(original))

        let output = try JSONEncoder().encode(value)
        let recovered = try JSONDecoder().decode(String.self, from: output)
        #expect(Data(recovered.utf8) == Data(original.utf8))
    }

    @Test("Erasing a tool result to Value must not rewrite its text")
    func toolResultRoundTrip() throws {
        let original = "data:text/plain,Hello%20World"
        let result = CallTool.Result(content: [
            .text(text: original, annotations: nil, _meta: nil),
        ])

        // The SDK uses this encode/decode-to-Value boundary for typed responses.
        let erased = try Value(result)
        let wire = try JSONEncoder().encode(erased)
        let recovered = try JSONDecoder().decode(CallTool.Result.self, from: wire)
        #expect(recovered.content.count == 1)
        guard case .text(let text, _, _) = recovered.content.first else {
            Issue.record("Expected a text content block")
            return
        }
        #expect(Data(text.utf8) == Data(original.utf8))
    }

    @Test("Explicit binary values retain their data-URI wire encoding")
    func explicitBinaryEncodingIsUnchanged() throws {
        let bytes = Data([0x00, 0x01, 0x02, 0xFF])
        let value = Value.data(mimeType: "application/octet-stream", bytes)
        let wire = try JSONEncoder().encode(value)
        let encoded = try JSONDecoder().decode(String.self, from: wire)

        #expect(encoded == "data:application/octet-stream;base64,AAEC/w==")
    }
}
