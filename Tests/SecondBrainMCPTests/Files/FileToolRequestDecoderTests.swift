import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `MCP file request decoder` {
    private let revision = "sha256:" + String(repeating: "a", count: 64)

    @Test
    func `Create arguments decode into shared request values`() throws {
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

    @Test
    func `Read arguments preserve format-specific options`() throws {
        let params = CallTool.Parameters(
            name: "read_file",
            arguments: [
                "format": .string("pdf"),
                "path": .string("references/manual.pdf"),
                "pages": .array([.int(7), .int(9)]),
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
        #expect(request.options.page == nil)
        #expect(request.options.pages == [7, 9])
    }

    @Test
    func `Update replacements decode in input order`() throws {
        let params = CallTool.Parameters(
            name: "update_file",
            arguments: [
                "format": .string("markdown"),
                "path": .string("notes/page.md"),
                "expected_revision": .string(revision),
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
        #expect(request.expectedRevision.rawValue == revision)
        #expect(request.replacements.count == 1)
        #expect(request.replacements.first?.oldText == "before")
        #expect(request.replacements.first?.newText == "after")
    }

    @Test
    func `Delete requires and preserves its expected revision`() throws {
        let params = CallTool.Parameters(
            name: "delete_file",
            arguments: [
                "format": .string("markdown"),
                "path": .string("notes/page.md"),
                "expected_revision": .string(revision),
            ]
        )

        guard case .delete(let request) = try FileToolRequestDecoder.decode(
            params,
            for: .delete
        ) else {
            Issue.record("Expected a delete request")
            return
        }

        #expect(request.expectedRevision.rawValue == revision)
    }

    @Test
    func `Expected revisions are strict`() {
        expectError(
            "Missing required parameter: expected_revision",
            decoding: CallTool.Parameters(
                name: FileToolName.delete.rawValue,
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/page.md"),
                    ]
            ),
            for: .delete
        )
        expectError(
            "Invalid expected_revision: expected sha256: followed by 64 lowercase hexadecimal digits",
            decoding: CallTool.Parameters(
                name: FileToolName.delete.rawValue,
                arguments: [
                    "format": .string("markdown"),
                    "path": .string("notes/page.md"),
                        "expected_revision": .string("sha256:ABC"),
                ]
            ),
            for: .delete
        )
    }

    @Test
    func `Invalid update mode retains its boundary error`() {
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
        arguments: FileToolName.allCases
    )
    func `Every CRUD decoder shares required path validation`(tool: FileToolName) {
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

    @Test
    func `Identity decoding distinguishes missing and unsupported formats`() {
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

    @Test
    func `Removed PDF selectors are rejected instead of ignored`() {
        expectError(
            "Unknown parameter: book_page",
            decoding: CallTool.Parameters(
                name: FileToolName.read.rawValue,
                arguments: [
                    "format": .string("pdf"),
                    "path": .string("references/manual.pdf"),
                    "book_page": .string("xii"),
                ]
            ),
            for: .read
        )
    }

    @Test
    func `Invalid create transforms receive a focused diagnostic`() {
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

    @Test
    func `Present arguments with wrong JSON types are rejected`() {
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
