import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct LogLineSemanticsTests {
    @Test("Log terminators end records without inventing a final empty record")
    func emptyAndTerminatedRecords() {
        let cases: [(String, [String])] = [
            ("", []), ("\n", [""]), ("\n\n", ["", ""]),
            ("one", ["one"]), ("one\n", ["one"]),
            ("one\n\n", ["one", ""]), ("one\n\nthree\n", ["one", "", "three"]),
            ("\r\n", [""]), ("one\r\ntwo\r\n", ["one", "two"]),
            ("one\r\n\r\n", ["one", ""]),
            ("one\r", ["one"]), ("one\u{2028}", ["one"]),
        ]
        for (source, expected) in cases {
            #expect(TextLineScanner.lineCount(in: source) == expected.count)
            let window = TextLineScanner.window(in: source, startingAt: 1, maximumLines: 20)
            #expect(window.lines == expected)
            #expect(window.totalLineCount == expected.count)
            #expect(window.firstLine == (expected.isEmpty ? nil : 1))
            #expect(window.lastLine == (expected.isEmpty ? nil : expected.count))
            let tail = TextLineScanner.tail(in: source, maximumLines: 2)
            #expect(tail.lines == Array(expected.suffix(2)))
            #expect(tail.totalLineCount == expected.count)
        }
    }

    @Test("Log creation counts records without rewriting their exact bytes")
    func creationSummaryPreservesBytes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try WritableFileTarget.resolve(
            path: "notes/app.log", format: .log, vaultPath: root.path
        )
        for (source, count) in [("", 0), ("\n", 1), ("one\ntwo\nthree\n", 3),
                                ("one\r\n\r\n", 2)] {
            let bytes = Data(source.utf8)
            let prepared = try LogFileOperations().prepareCreate(
                TextFileCreateInput(data: bytes, tags: []), target: target
            )
            #expect(prepared.data == bytes)
            guard case .text(let summary) = prepared.output.contents.first else {
                Issue.record("Expected a creation summary")
                continue
            }
            #expect(summary == "Created notes/app.log (\(count) lines)")
        }
    }

    @Test("Public log tail and ranges omit only the final terminator")
    func publicTailAndRange() async throws {
        for source in ["one\ntwo\nthree\n", "one\r\ntwo\r\nthree\r\n"] {
            try await withLog(source) { controller, _, revision in
                let tail = try await read(controller, ["tail_lines": .int(2)])
                #expect(try text(tail) == "Log: notes/app.log (last 2 of 3 lines)\n\ntwo\nthree")
                #expect(tail.structuredContent?.objectValue?["revision"]?.stringValue == revision)
                #expect(tail.structuredContent?.objectValue?["text_window"] == nil)

                let range = try await read(controller, ["start_line": .int(2), "max_lines": .int(2)])
                #expect(try text(range) == "Log: notes/app.log (lines 2-3 of 3)\n\ntwo\nthree")
                #expect(range.structuredContent?.objectValue?["revision"]?.stringValue == revision)

                let beyond = try await read(controller, ["start_line": .int(4), "max_lines": .int(2)])
                #expect(try text(beyond) == "Log: notes/app.log (no lines from line 4 of 3)\n\n")
                let all = try await read(controller, [:])
                #expect(try text(all) == "Log: notes/app.log (last 3 of 3 lines)\n\none\ntwo\nthree")
            }
        }
    }

    @Test("Public log tails retain deliberately empty records")
    func publicBlankRecords() async throws {
        for source in ["one\n\n\n", "one\r\n\r\n\r\n"] {
            try await withLog(source) { controller, _, _ in
                let tail = try await read(controller, ["tail_lines": .int(2)])
                #expect(try text(tail) == "Log: notes/app.log (last 2 of 3 lines)\n\n\n")
                let blank = try await read(controller, ["start_line": .int(2), "max_lines": .int(1)])
                #expect(try text(blank) == "Log: notes/app.log (lines 2-2 of 3)\n\n")
            }
        }
    }

    @Test("Empty logs have zero records while one delimiter is one empty record")
    func publicEmptyAndSingleDelimiter() async throws {
        for (source, count) in [("", 0), ("\n", 1), ("\r\n", 1)] {
            try await withLog(source) { controller, _, revision in
                let tail = try await read(controller, ["tail_lines": .int(2)])
                #expect(try text(tail) == "Log: notes/app.log (last \(count) of \(count) lines)\n\n")
                #expect(tail.structuredContent?.objectValue?["revision"]?.stringValue == revision)
            }
        }
    }

    @Test("Log byte continuation preserves terminators and exact snapshot revisions")
    func byteReadsPreserveBytesAndRevisions() async throws {
        let source = "é\r\n🧠\r\n\n"
        try await withLog(source) { controller, file, revision in
            var combined = ""
            var offset = 0
            for _ in 0..<10 {
                var arguments: [String: Value] = ["max_bytes": .int(4), "byte_offset": .int(offset)]
                if offset > 0 { arguments["expected_revision"] = .string(revision) }
                let result = try await read(controller, arguments)
                try #require(result.isError != true)
                let chunk = try text(result)
                combined += chunk
                let facts = try #require(result.structuredContent?.objectValue)
                #expect(facts["revision"]?.stringValue == revision)
                let window = try #require(facts["text_window"]?.objectValue)
                #expect(window["byte_count"]?.intValue == chunk.utf8.count)
                #expect(window["byte_offset"]?.intValue == offset)
                #expect(window["total_bytes"]?.intValue == source.utf8.count)
                guard let next = window["next_byte_offset"]?.intValue else { break }
                try #require(next > offset)
                offset = next
            }
            #expect(Data(combined.utf8) == Data(source.utf8))
            #expect(try Data(contentsOf: file) == Data(source.utf8))

            try Data((source + "changed\n").utf8).write(to: file)
            let stale = try await read(controller, [
                "max_bytes": .int(4), "byte_offset": .int(4),
                "expected_revision": .string(revision),
            ])
            #expect(stale.isError == true)
        }
    }

    private func read(_ controller: FileToolController, _ options: [String: Value]) async throws -> CallTool.Result {
        let arguments: [String: Value] = ["format": .string("log"), "path": .string("notes/app.log")]
        let parameters = CallTool.Parameters(name: "read_file", arguments: arguments.merging(options) { _, new in new })
        let encoded = try JSONEncoder().encode(parameters)
        return try await controller.call(JSONDecoder().decode(CallTool.Parameters.self, from: encoded))
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case .text(let value, _, _) = result.content.first else { throw MissingText() }
        return value
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogLineSemanticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("references"), withIntermediateDirectories: true)
        return root
    }

    private func withLog(
        _ source: String,
        operation: (FileToolController, URL, String) async throws -> Void
    ) async throws {
        let root = try makeRoot()
        let support = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: support.rootURL)
        }
        let file = root.appendingPathComponent("notes/app.log")
        let bytes = Data(source.utf8)
        try bytes.write(to: file)
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root.path, readOnly: true)
        try await operation(
            FileToolController(readOnly: true, files: runtime.files), file,
            FileSnapshot(data: bytes, modifiedDate: nil).revision.rawValue
        )
    }

    private struct MissingText: Error {}
}
