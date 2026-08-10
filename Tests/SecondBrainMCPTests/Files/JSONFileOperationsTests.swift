import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `JSON format semantics` {
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
    func `Creation preserves valid JSON bytes and accepts top-level scalars`() throws {
        let target = try makeTarget()
        let operations = JSONFileOperations()
        let source = "{\n  \"z\": 1,\n  \"a\": [true, null]\n}\n"

        let prepared = try operations.prepareCreate(
            TextFileCreateInput(data: Data(source.utf8), tags: []),
            target: target
        )
        #expect(prepared.data == Data(source.utf8))

        for scalar in ["42", "1e309", "true", "null", #""text""#] {
            let data = Data(scalar.utf8)
            #expect(try operations.prepareCreate(
                TextFileCreateInput(data: data, tags: []),
                target: target
            ).data == data)
        }
    }

    @Test
    func `Malformed JSON is rejected during validation`() throws {
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
            try JSONFileOperations.validate(
                Data(excessiveNesting.utf8),
                path: target.relativePath
            )
        }
    }

    @Test
    func `JSON validation enforces the shared resource bound first`() throws {
        let target = try makeTarget()
        let oversized = Data(
            repeating: 0x20,
            count: FileResourcePolicy.maximumBytes(for: .json) + 1
        )
        #expect(throws: FileResourcePolicy.Violation.self) {
            try JSONFileOperations.validate(
                oversized,
                path: target.relativePath
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
            path: "notes/data.json",
            format: .json,
            vaultPath: root
        )
    }
}
