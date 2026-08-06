import MCP
import Testing
@testable import SecondBrainMCP

@Suite("MCP file request decoder")
struct FileToolRequestDecoderTests {
    @Test("Create arguments decode into shared request values")
    func createRequest() throws {
        let params = CallTool.Parameters(
            name: "create_file",
            arguments: [
                "format": .string("gif"),
                "path": .string("notes/demo.gif"),
                "source": .string("/tmp/demo.mov"),
                "tags": .array([.string("demo"), .string("video")]),
                "transform": .string("video_to_gif"),
            ]
        )

        guard case .create(let request) = try FileToolRequestDecoder.decode(
            params,
            for: .create
        ) else {
            Issue.record("Expected a create request")
            return
        }

        #expect(request.format == .gif)
        #expect(request.path == "notes/demo.gif")
        #expect(request.source == "/tmp/demo.mov")
        #expect(request.tags == ["demo", "video"])
        #expect(request.transform == .videoToGIF)
    }

    @Test("Read arguments preserve format-specific options")
    func readRequest() throws {
        let params = CallTool.Parameters(
            name: "read_file",
            arguments: [
                "format": .string("pdf"),
                "path": .string("references/manual.pdf"),
                "page": .int(7),
                "query": .string("architecture"),
                "max_pages": .int(3),
            ]
        )

        guard case .read(let request) = try FileToolRequestDecoder.decode(
            params,
            for: .read
        ) else {
            Issue.record("Expected a read request")
            return
        }

        #expect(request.format == .pdf)
        #expect(request.options.page == 7)
        #expect(request.options.query == "architecture")
        #expect(request.options.maxPages == 3)
    }

    @Test("Update replacements decode in input order")
    func updateRequest() throws {
        let params = CallTool.Parameters(
            name: "update_file",
            arguments: [
                "format": .string("markdown"),
                "path": .string("notes/page.md"),
                "mode": .string("patch"),
                "replacements": .array([
                    .object([
                        "old_text": .string("before"),
                        "new_text": .string("after"),
                    ]),
                ]),
            ]
        )

        guard case .update(let request) = try FileToolRequestDecoder.decode(
            params,
            for: .update
        ) else {
            Issue.record("Expected an update request")
            return
        }

        #expect(request.mode == .patch)
        #expect(request.replacements.count == 1)
        #expect(request.replacements.first?.oldText == "before")
        #expect(request.replacements.first?.newText == "after")
    }

    @Test("Invalid update mode retains its boundary error")
    func invalidUpdateMode() {
        let params = CallTool.Parameters(
            name: "update_file",
            arguments: [
                "format": .string("markdown"),
                "path": .string("notes/page.md"),
                "mode": .string("merge"),
            ]
        )

        expectError(
            "Invalid update mode: merge",
            decoding: params,
            for: .update
        )
    }

    @Test(
        "Every CRUD decoder shares required path validation",
        arguments: FileToolName.allCases
    )
    func missingPath(tool: FileToolName) {
        let params = CallTool.Parameters(
            name: tool.rawValue,
            arguments: ["format": .string("markdown")]
        )

        expectError(
            "Missing required parameter: path",
            decoding: params,
            for: tool
        )
    }

    @Test("Identity decoding distinguishes missing and unsupported formats")
    func invalidFormats() {
        expectError(
            "Missing required parameter: format",
            decoding: CallTool.Parameters(
                name: FileToolName.read.rawValue,
                arguments: ["path": .string("notes/page.md")]
            ),
            for: .read
        )
        expectError(
            "Unsupported file format: archive",
            decoding: CallTool.Parameters(
                name: FileToolName.read.rawValue,
                arguments: [
                    "format": .string("archive"),
                    "path": .string("notes/page.archive"),
                ]
            ),
            for: .read
        )
    }

    @Test("Invalid create transforms receive a focused diagnostic")
    func invalidCreateTransform() {
        expectError(
            "Invalid create transform: transcode",
            decoding: CallTool.Parameters(
                name: FileToolName.create.rawValue,
                arguments: [
                    "format": .string("gif"),
                    "path": .string("notes/demo.gif"),
                    "transform": .string("transcode"),
                ]
            ),
            for: .create
        )
    }

    @Test("Present arguments with wrong JSON types are rejected")
    func invalidArgumentTypes() {
        expectError(
            "Invalid parameter 'mode': expected string",
            decoding: CallTool.Parameters(
                name: FileToolName.update.rawValue,
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/page.md"),
                    "mode": .int(1),
                ]
            ),
            for: .update
        )
        expectError(
            "Invalid parameter 'raw': expected boolean",
            decoding: CallTool.Parameters(
                name: FileToolName.read.rawValue,
                arguments: [
                    "format": .string("har"),
                    "path": .string("notes/capture.har"),
                    "raw": .string("true"),
                ]
            ),
            for: .read
        )
        expectError(
            "Invalid parameter 'tags': expected array of strings",
            decoding: CallTool.Parameters(
                name: FileToolName.create.rawValue,
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/page.md"),
                    "tags": .array([.string("valid"), .int(1)]),
                ]
            ),
            for: .create
        )
        expectError(
            "Invalid parameter 'replacements': expected array",
            decoding: CallTool.Parameters(
                name: FileToolName.update.rawValue,
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/page.md"),
                    "replacements": .string("not-an-array"),
                ]
            ),
            for: .update
        )
    }

    private func expectError(
        _ expected: String,
        decoding params: CallTool.Parameters,
        for tool: FileToolName
    ) {
        do {
            _ = try FileToolRequestDecoder.decode(params, for: tool)
            Issue.record("Expected decoding to fail")
        } catch let error as FileToolRequestDecoder.DecodingError {
            #expect(error.description == expected)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
