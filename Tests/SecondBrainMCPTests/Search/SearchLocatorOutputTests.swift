import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct SearchLocatorOutputTests {
    private let locatorLimit = 4 * 1_024
    private let structuredLimit = 256 * 1_024
    private let resultLimit = 768 * 1_024

    @Test
    func oversizedCanvasLocatorIsAnExplicitFileFailureNotAnUnboundedResponse() async throws {
        let oversizedID = String(repeating: "x", count: 400_000)
        try await withFixture { runtime, root in
            try Data("needle".utf8).write(to: root.appendingPathComponent("notes/a.md"))
            try canvas([(oversizedID, "needle needle")])
                .write(to: root.appendingPathComponent("notes/z.canvas"))
            let result = try await search(runtime)
            let object = try facts(result)
            let values = try #require(object["results"]?.arrayValue)
            let structuredBytes = try JSONEncoder().encode(try #require(result.structuredContent)).count
            let resultBytes = try JSONEncoder().encode(result).count
            print("CANVAS_LOCATOR_OUTPUT structured_bytes=\(structuredBytes) call_tool_result_bytes=\(resultBytes)")
            #expect(values.compactMap { $0.objectValue?["path"]?.stringValue } == ["notes/a.md"])
            #expect(structuredBytes <= structuredLimit)
            #expect(resultBytes <= resultLimit)
            try expectFailure(object, path: "notes/z.canvas")
        }
    }

    @Test
    func exactEncodedLocatorBoundaryHandlesUnicodeAndJSONEscapes() async throws {
        for prefix in ["plain", String(repeating: "🧠", count: 700),
                       String(repeating: "\u{0}", count: 500),
                       String(repeating: "\\\"/\n", count: 200)] {
            let exactID = try identifier(at: locatorLimit, path: "notes/a.canvas", prefix: prefix)
            let aboveID = exactID + "x"
            let exactBytes = try encodedLocator(path: "notes/a.canvas", id: exactID).count
            let aboveBytes = try encodedLocator(path: "notes/b.canvas", id: aboveID).count
            try #require(exactBytes == locatorLimit)
            try #require(aboveBytes == locatorLimit + 1)
            try await withFixture { runtime, root in
                try canvas([(exactID, "needle")]).write(to: root.appendingPathComponent("notes/a.canvas"))
                try canvas([(aboveID, "needle")]).write(to: root.appendingPathComponent("notes/b.canvas"))
                let object = try facts(await search(runtime))
                let values = try #require(object["results"]?.arrayValue)
                #expect(values.count == 1)
                #expect(values.first?.objectValue?["canvas_node_id"]?.stringValue == exactID)
                try expectFailure(object, path: "notes/b.canvas")
            }
        }
    }

    @Test
    func failedCanvasCannotEvictHealthyMatchesAndItsRepairStalesTheCursor() async throws {
        try await withFixture { runtime, root in
            for name in ["a.md", "b.md"] {
                try Data("needle".utf8).write(to: root.appendingPathComponent("notes/\(name)"))
            }
            let canvasURL = root.appendingPathComponent("notes/z.canvas")
            try canvas([
                ("early-good-id", "needle needle needle"),
                (String(repeating: "z", count: 5_000), "needle needle"),
            ]).write(to: canvasURL)
            let first = try facts(await search(runtime, limit: 1))
            #expect(first["results"]?.arrayValue?.first?.objectValue?["path"]?.stringValue == "notes/a.md")
            try expectFailure(first, path: "notes/z.canvas")
            let cursor = try #require(first["next_cursor"]?.stringValue)
            let second = try facts(await search(runtime, limit: 1, cursor: cursor))
            #expect(second["results"]?.arrayValue?.first?.objectValue?["path"]?.stringValue == "notes/b.md")
            #expect(second["next_cursor"] == nil)
            try expectFailure(second, path: "notes/z.canvas")
            try canvas([("repaired", "needle needle")]).write(to: canvasURL)
            let stale = try await search(runtime, limit: 1, cursor: cursor)
            #expect(stale.isError == true)
        }
    }

    @Test
    func discoveryBudgetDoesNotInvalidateStoredIDsOrTargetedReads() async throws {
        let longID = String(repeating: "🧠", count: 700)
        let omittedID = String(repeating: "x", count: 5_000)
        try await withFixture { runtime, root in
            try canvas([(longID, "needle")]).write(to: root.appendingPathComponent("notes/a.canvas"))
            try canvas([(omittedID, "known field")]).write(to: root.appendingPathComponent("notes/b.canvas"))
            let found = try facts(await search(runtime))
            let locator = try #require(found["results"]?.arrayValue?.first?.objectValue)
            #expect(locator["canvas_node_id"]?.stringValue == longID)
            let reader = FileToolController(readOnly: true, files: runtime.files)
            for (path, id, expected) in [
                ("notes/a.canvas", longID, "needle"),
                ("notes/b.canvas", omittedID, "known field"),
            ] {
                let read = try await reader.call(parameters("read_file", [
                    "path": .string(path), "format": .string("canvas"),
                    "canvas_node_id": .string(id), "canvas_field": .string("text"),
                ]))
                try #require(read.isError != true)
                #expect(read.structuredContent?.objectValue?["canvas_node_id"]?.stringValue == id)
                guard case .text(let text, _, _) = read.content.first else {
                    Issue.record("Expected selected Canvas field text")
                    continue
                }
                #expect(text == expected)
            }
        }
    }

    @Test
    func fiftyWorstCaseLocatorsRemainWithinBothPublicResponseBudgets() async throws {
        try await withFixture { runtime, root in
            for index in 0..<51 {
                let path = String(format: "notes/%02d.canvas", index)
                let id = try identifier(at: locatorLimit, path: path,
                                        prefix: String(repeating: "\u{0}", count: 500))
                try canvas([(id, "needle")]).write(to: root.appendingPathComponent(path))
            }
            let result = try await search(runtime, limit: 50)
            let object = try facts(result)
            let values = try #require(object["results"]?.arrayValue)
            #expect(values.count == 50)
            #expect(object["coverage"]?.objectValue?["complete"]?.boolValue == true)
            #expect(object["next_cursor"]?.stringValue != nil)
            let structuredBytes = try JSONEncoder().encode(try #require(result.structuredContent)).count
            let resultBytes = try JSONEncoder().encode(result).count
            #expect(structuredBytes <= structuredLimit)
            #expect(resultBytes <= resultLimit)
            print("CANVAS_DENSE_LOCATOR_OUTPUT structured_bytes=\(structuredBytes) call_tool_result_bytes=\(resultBytes)")
        }
    }

    private func identifier(at byteCount: Int, path: String, prefix: String) throws -> String {
        let current = try encodedLocator(path: path, id: prefix).count
        try #require(current <= byteCount)
        return prefix + String(repeating: "a", count: byteCount - current)
    }

    private func encodedLocator(path: String, id: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(VaultSearchResult(
            path: path, format: .canvas, canvasNodeID: id, canvasField: "text"
        ))
    }

    private func expectFailure(_ object: [String: Value], path: String) throws {
        let coverage = try #require(object["coverage"]?.objectValue)
        #expect(coverage["complete"]?.boolValue == false)
        #expect(coverage["failed_files"]?.intValue == 1)
        let sample = try #require(coverage["samples"]?.arrayValue?.first?.objectValue)
        #expect(sample["path"]?.stringValue == path)
        #expect(sample["reason"]?.stringValue == "file_limit")
    }

    private func facts(_ result: CallTool.Result) throws -> [String: Value] {
        try #require(result.isError != true)
        return try #require(result.structuredContent?.objectValue)
    }

    private func search(_ runtime: VaultRuntime, limit: Int = 50,
                        cursor: String? = nil) async throws -> CallTool.Result {
        var arguments: [String: Value] = [
            "location": .string("notes"), "query": .string("needle"), "limit": .int(limit),
        ]
        if let cursor { arguments["cursor"] = .string(cursor) }
        return try await SearchToolController(search: runtime.search)
            .call(parameters("search_vault", arguments))
    }

    private func parameters(_ name: String, _ arguments: [String: Value]) throws -> CallTool.Parameters {
        let data = try JSONEncoder().encode(CallTool.Parameters(name: name, arguments: arguments))
        return try JSONDecoder().decode(CallTool.Parameters.self, from: data)
    }

    private func canvas(_ nodes: [(String, String)]) throws -> Data {
        let values: [[String: Any]] = nodes.map { id, text in
            ["id": id, "type": "text", "x": 0, "y": 0, "width": 100, "height": 100, "text": text]
        }
        return try JSONSerialization.data(withJSONObject: ["nodes": values, "edges": []],
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func withFixture(_ operation: (VaultRuntime, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchLocatorOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("references"),
                                                withIntermediateDirectories: true)
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataDirectory.rootURL)
        }
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root.path, readOnly: true)
        try await operation(runtime, root)
    }
}
