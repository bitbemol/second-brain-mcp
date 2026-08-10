import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `JSON file operations` {
    @Test
    func `Cancellation is not misreported as malformed JSON`() async throws {
        let target = try makeTarget()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try JSONFileOperations().prepareCreate(
                TextFileCreateInput(data: Data("{}".utf8), tags: []),
                target: target
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `Creation and reading preserve valid JSON bytes`() throws {
        let target = try makeTarget()
        let source = "{\n  \"z\": 1,\n  \"a\": [true, null]\n}\n"
        let operations = JSONFileOperations()

        let prepared = try operations.prepareCreate(
            TextFileCreateInput(data: Data(source.utf8), tags: []),
            target: target
        )
        #expect(prepared.data == Data(source.utf8))

        let output = try operations.read(
            ReadFileRequest(
                format: .json,
                path: target.relativePath,
                options: .default
            ),
            target: target.readable,
            snapshot: FileSnapshot(data: prepared.data, modifiedDate: nil)
        )
        guard case .text(let returned) = output.contents.first else {
            Issue.record("Expected raw JSON text")
            return
        }
        #expect(returned == source)

        // RFC 8259 permits a scalar at the top level; JSON support is not
        // artificially limited to objects and arrays.
        _ = try operations.prepareCreate(
            TextFileCreateInput(data: Data("42".utf8), tags: []),
            target: target
        )
        let largeNumber = Data("1e309".utf8)
        #expect(try operations.prepareCreate(
            TextFileCreateInput(data: largeNumber, tags: []),
            target: target
        ).data == largeNumber)
    }

    @Test
    func `Malformed JSON is rejected on creation and after updates`() throws {
        let target = try makeTarget()
        let operations = JSONFileOperations()
        for malformed in [
            #"{"broken":}"#,
            #"{"trailing":1,}"#,
            #"[1,2,]"#,
            #"{} {}"#,
            #"{"leading-zero":01}"#,
            "+1",
            "1.",
            "1e",
            #""bad\xescape""#,
            #""short\u12""#,
            #"{"missing-colon" 1}"#,
            #"[1 2]"#,
            "{\"control\":\"line\nbreak\"}",
        ] {
            #expect(throws: JSONFileOperations.InvalidJSON.self) {
                try operations.prepareCreate(
                    TextFileCreateInput(
                        data: Data(malformed.utf8),
                        tags: []
                    ),
                    target: target
                )
            }
        }

        let excessiveNesting = String(repeating: "[", count: 513)
            + "0"
            + String(repeating: "]", count: 513)
        #expect(throws: JSONFileOperations.InvalidJSON.self) {
            try operations.prepareCreate(
                TextFileCreateInput(
                    data: Data(excessiveNesting.utf8),
                    tags: []
                ),
                target: target
            )
        }

        let original = Data(#"{"enabled":false}"#.utf8)
        #expect(throws: JSONFileOperations.InvalidJSON.self) {
            try operations.prepareUpdate(
                update(
                    target: target,
                    mode: .patch,
                    replacements: [
                        TextReplacement(oldText: "false", newText: "}"),
                    ]
                ),
                target: target,
                snapshot: FileSnapshot(data: original, modifiedDate: nil)
            )
        }
    }

    @Test
    func `Leading UTF-8 BOM survives reads and patch updates`() throws {
        let target = try makeTarget()
        let operations = JSONFileOperations()
        let original = Data([0xef, 0xbb, 0xbf]) + Data(#"{"value":1}"#.utf8)
        let prepared = try operations.prepareCreate(
            TextFileCreateInput(data: original, tags: []),
            target: target
        )
        let snapshot = FileSnapshot(data: prepared.data, modifiedDate: nil)
        let read = try operations.read(
            ReadFileRequest(
                format: .json,
                path: target.relativePath,
                options: .default
            ),
            target: target.readable,
            snapshot: snapshot
        )
        guard case .text(let text) = read.contents.first else {
            Issue.record("Expected BOM-preserving JSON text")
            return
        }
        #expect(Data(text.utf8) == original)

        let patched = try operations.prepareUpdate(
            UpdateFileRequest(
                mutationID: MutationID(),
                expectedRevision: snapshot.revision,
                format: .json,
                path: target.relativePath,
                content: nil,
                mode: .patch,
                replacements: [
                    TextReplacement(oldText: "1", newText: "2"),
                ]
            ),
            target: target,
            snapshot: snapshot
        )
        #expect(patched.data.starts(with: [0xef, 0xbb, 0xbf]))
        #expect(try TextFileSupport.stringPreservingByteOrderMark(
            from: patched.data
        ).hasSuffix(#"{"value":2}"#))
    }

    @Test
    func `Oversized updates fail before JSON syntax work`() throws {
        let target = try makeTarget()
        let snapshot = FileSnapshot(data: Data("0".utf8), modifiedDate: nil)
        let oversized = String(
            repeating: " ",
            count: FileFormat.json.maximumFileBytes
        ) + "0"

        #expect(throws: FileResourcePolicy.Violation.self) {
            try JSONFileOperations().prepareUpdate(
                UpdateFileRequest(
                    mutationID: MutationID(),
                    expectedRevision: snapshot.revision,
                    format: .json,
                    path: target.relativePath,
                    content: oversized,
                    mode: .replace,
                    replacements: []
                ),
                target: target,
                snapshot: snapshot
            )
        }
    }

    @Test
    func `JSON supports replacement and exact patches but not append`() throws {
        let target = try makeTarget()
        let operations = JSONFileOperations()
        let original = Data(#"{"enabled":false,"count":1}"#.utf8)
        let snapshot = FileSnapshot(data: original, modifiedDate: nil)

        let patched = try operations.prepareUpdate(
            update(
                target: target,
                mode: .patch,
                replacements: [
                    TextReplacement(oldText: "false", newText: "true"),
                ]
            ),
            target: target,
            snapshot: snapshot
        )
        #expect(try TextFileSupport.string(from: patched.data) ==
            #"{"enabled":true,"count":1}"#)

        let replaced = try operations.prepareUpdate(
            update(
                target: target,
                mode: .replace,
                content: "[1, 2, 3]"
            ),
            target: target,
            snapshot: snapshot
        )
        #expect(try TextFileSupport.string(from: replaced.data) == "[1, 2, 3]")

        #expect(throws: FileRoutingError.self) {
            try operations.prepareUpdate(
                update(target: target, mode: .append, content: "{}"),
                target: target,
                snapshot: snapshot
            )
        }
    }

    private func makeTarget() throws -> WritableFileTarget {
        let root = NSTemporaryDirectory()
            + "JSONFileOperationsTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return try WritableFileTarget.resolve(
            path: "notes/fixture.json",
            format: .json,
            vaultPath: root
        )
    }

    private func update(
        target: WritableFileTarget,
        mode: FileUpdateMode,
        content: String? = nil,
        replacements: [TextReplacement] = []
    ) -> UpdateFileRequest {
        UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: FileSnapshot(
                data: Data(#"{"enabled":false,"count":1}"#.utf8),
                modifiedDate: nil
            ).revision,
            format: .json,
            path: target.relativePath,
            content: content,
            mode: mode,
            replacements: replacements
        )
    }
}
