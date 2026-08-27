import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `Canvas locator reads` {
    @Test
    func `Search locators select a late Canvas field without unrelated chunks`() async throws {
        let wanted = "distinct-target-marker café 🧠"
        let bytes = try document([
            node(id: "early", type: "text", fields: ["text": String(repeating: "unrelated ", count: 14_000)]),
            node(id: "late", type: "text", fields: ["text": wanted]),
        ])
        try await withFixture(bytes) { runtime, _ in
            let search = SearchToolController(search: runtime.search)
            let found = try await search.call(try parameters("search_vault", [
                "location": .string("notes"), "query": .string("distinct-target-marker"),
            ]))
            #expect(found.isError != true)
            let locators = try #require(found.structuredContent?.objectValue?["results"]?.arrayValue)
            let locator = try #require(locators.first?.objectValue)
            #expect(locators.count == 1)
            #expect(locator["canvas_node_id"]?.stringValue == "late")
            #expect(locator["canvas_field"]?.stringValue == "text")

            let controller = FileToolController(readOnly: true, files: runtime.files)
            var rawCalls = 0
            var rawContentBytes = 0
            var rawResponseBytes = 0
            var accumulated = ""
            var offset = 0
            var revision: String?
            repeat {
                var arguments: [String: Value] = [:]
                if offset > 0 {
                    arguments["byte_offset"] = .int(offset)
                    arguments["expected_revision"] = .string(try #require(revision))
                }
                let raw = try await read(controller, arguments)
                #expect(raw.isError != true)
                let text = try firstText(raw)
                accumulated += text
                rawCalls += 1
                rawContentBytes += text.utf8.count
                rawResponseBytes += try JSONEncoder().encode(raw).count
                let facts = try #require(raw.structuredContent?.objectValue)
                revision = facts["revision"]?.stringValue
                #expect(facts["canvas_node_id"] == nil)
                if accumulated.contains("distinct-target-marker") { break }
                offset = try #require(facts["text_window"]?.objectValue?["next_byte_offset"]?.intValue)
                #expect(rawCalls < 100)
            } while rawCalls < 100
            #expect(rawCalls > 1)
            #expect(accumulated.contains("distinct-target-marker"))
            print("CANVAS_RAW_READ_BASELINE calls=\(rawCalls) content_bytes=\(rawContentBytes) response_bytes=\(rawResponseBytes)")

            let selected = try await read(controller, [
                "canvas_node_id": try #require(locator["canvas_node_id"]),
                "canvas_field": try #require(locator["canvas_field"]),
            ])
            try #require(selected.isError != true)
            #expect(try firstText(selected) == wanted)
            let facts = try #require(selected.structuredContent?.objectValue)
            #expect(facts["canvas_node_id"]?.stringValue == "late")
            #expect(facts["canvas_field"]?.stringValue == "text")
            #expect(facts["revision"]?.stringValue == revision)
            #expect(facts["text_window"]?.objectValue?["total_bytes"]?.intValue == wanted.utf8.count)
            #expect(facts["text_window"]?.objectValue?["next_byte_offset"] == nil)
            let selectedBytes = try JSONEncoder().encode(selected).count
            #expect(selectedBytes < rawResponseBytes / 10)
            print("CANVAS_SELECTED_READ calls=1 content_bytes=\(wanted.utf8.count) response_bytes=\(selectedBytes)")
        }
    }

    @Test
    func `Selected UTF8 windows carry selectors and guard the complete raw revision`() async throws {
        let selectedText = "A🧠é\nZ"
        let bytes = try document([
            node(id: "other", type: "text", fields: ["text": "before"]),
            node(id: "selected", type: "text", fields: ["text": selectedText]),
        ])
        try await withFixture(bytes) { runtime, root in
            let controller = FileToolController(readOnly: true, files: runtime.files)
            let selector: [String: Value] = [
                "canvas_node_id": .string("selected"), "canvas_field": .string("text"),
                "max_bytes": .int(4),
            ]
            let first = try await read(controller, selector)
            try #require(first.isError != true)
            #expect(try firstText(first) == "A")
            let revision = try #require(first.structuredContent?.objectValue?["revision"]?.stringValue)
            #expect(revision == FileSnapshot(data: bytes, modifiedDate: nil).revision.rawValue)
            var continuation = selector
            continuation["byte_offset"] = .int(1)
            continuation["expected_revision"] = .string(revision)
            let second = try await read(controller, continuation)
            #expect(second.isError != true)
            #expect(try firstText(second) == "🧠")
            let secondFacts = try #require(second.structuredContent?.objectValue)
            #expect(secondFacts["canvas_node_id"]?.stringValue == "selected")
            #expect(secondFacts["canvas_field"]?.stringValue == "text")
            #expect(secondFacts["text_window"]?.objectValue?["total_bytes"]?.intValue == 9)
            #expect(secondFacts["text_window"]?.objectValue?["next_byte_offset"]?.intValue == 5)
            let mirroredFacts = try #require(second.content.last)
            guard case .text(let metadataText, _, _) = mirroredFacts else {
                Issue.record("Expected selector and revision metadata for text-only clients")
                return
            }
            let mirrored = try #require(JSONSerialization.jsonObject(with: Data(metadataText.utf8)) as? [String: Any])
            #expect(mirrored["canvas_node_id"] as? String == "selected")
            #expect(mirrored["canvas_field"] as? String == "text")

            continuation["byte_offset"] = .int(5)
            let last = try await read(controller, continuation)
            #expect(try firstText(last) == "é\nZ")
            #expect(last.structuredContent?.objectValue?["text_window"]?.objectValue?["next_byte_offset"] == nil)

            continuation["byte_offset"] = .int(2)
            #expect(try await read(controller, continuation).isError == true)
            continuation["byte_offset"] = .int(1)
            continuation.removeValue(forKey: "expected_revision")
            #expect(try await read(controller, continuation).isError == true)

            let changed = try document([
                node(id: "other", type: "text", fields: ["text": "after"]),
                node(id: "selected", type: "text", fields: ["text": selectedText]),
            ])
            try changed.write(to: root.appendingPathComponent("notes/board.canvas"), options: .atomic)
            continuation["expected_revision"] = .string(revision)
            let stale = try await read(controller, continuation)
            #expect(stale.isError == true)
            let staleMessage = try firstText(stale)
            #expect(staleMessage.hasPrefix("Error: File changed since it was read:"))
        }
    }

    @Test
    func `Every present Canvas field including empty values has an exact read projection`() async throws {
        let longID = String(repeating: "🧠", count: 700)
        let bytes = try document([
            node(id: longID, type: "text", fields: ["text": ""]),
            node(id: "", type: "text", fields: ["text": "empty ID remains valid"]),
            node(id: "file", type: "file", fields: ["file": "notes/target.md", "subpath": "#Heading"]),
            node(id: "link", type: "link", fields: ["url": "https://example.invalid/"]),
            node(id: "group", type: "group", fields: ["label": "", "background": "notes/background.png"]),
        ])
        try await withFixture(bytes) { runtime, _ in
            let controller = FileToolController(readOnly: true, files: runtime.files)
            for (id, field, expected) in [
                (longID, "text", ""), ("", "text", "empty ID remains valid"),
                ("file", "file", "notes/target.md"),
                ("file", "subpath", "#Heading"), ("link", "url", "https://example.invalid/"),
                ("group", "label", ""), ("group", "background", "notes/background.png"),
            ] {
                let result = try await read(controller, [
                    "canvas_node_id": .string(id), "canvas_field": .string(field),
                ])
                try #require(result.isError != true)
                #expect(try firstText(result) == expected)
                let facts = try #require(result.structuredContent?.objectValue)
                #expect(facts["canvas_node_id"]?.stringValue == id)
                #expect(facts["text_window"]?.objectValue?["total_bytes"]?.intValue == expected.utf8.count)
                #expect(facts["text_window"]?.objectValue?["next_byte_offset"] == nil)
            }
        }
    }

    @Test
    func `Canvas selection validates the whole document and rejects absent fields`() async throws {
        let valid = node(id: "selected", type: "text", fields: ["text": "safe"])
        for nodes in [
            [valid],
            [valid, node(id: "selected", type: "text", fields: ["text": "duplicate"])],
            [valid, ["id": "invalid", "type": "text", "text": "missing geometry"]],
        ] {
            try await withFixture(try document(nodes)) { runtime, _ in
                let controller = FileToolController(readOnly: true, files: runtime.files)
                if nodes.count == 1 {
                    for (id, field) in [("missing", "text"), ("selected", "label")] {
                        let rejected = try await read(controller, [
                            "canvas_node_id": .string(id), "canvas_field": .string(field),
                        ])
                        #expect(rejected.isError == true)
                    }
                } else {
                    let rejected = try await read(controller, [
                        "canvas_node_id": .string("selected"), "canvas_field": .string("text"),
                    ])
                    #expect(rejected.isError == true)
                }
            }
        }
    }

    @Test
    func `Canvas selector pairs reject wrong types formats and incompatible modes`() async throws {
        try await withFixture(try document([
            node(id: "selected", type: "text", fields: ["text": "safe"]),
        ])) { runtime, _ in
            let controller = FileToolController(readOnly: true, files: runtime.files)
            let base: [String: Value] = [
                "canvas_node_id": .string("selected"), "canvas_field": .string("text"),
            ]
            let invalid: [[String: Value]] = [
                ["canvas_node_id": .string("selected")],
                ["canvas_field": .string("text")],
                base.merging(["canvas_node_id": .int(1)]) { _, new in new },
                base.merging(["canvas_field": .string("x")]) { _, new in new },
                base.merging(["view": .string("metadata")]) { _, new in new },
                base.merging(["page": .int(1)]) { _, new in new },
                base.merging(["pages": .array([.int(1)])]) { _, new in new },
                base.merging(["page_range": .string("1-2")]) { _, new in new },
                base.merging(["tail_lines": .int(1)]) { _, new in new },
                base.merging(["start_line": .int(1)]) { _, new in new },
                base.merging(["max_lines": .int(1)]) { _, new in new },
                base.merging(["format": .string("json"), "path": .string("notes/absent.json")]) { _, new in new },
            ]
            for arguments in invalid {
                let rejected = try await read(controller, arguments)
                #expect(rejected.isError == true)
            }
        }
    }

    @Test
    func `Read schemas advertise Canvas selector pairs and exact projected metadata`() throws {
        let capabilities = FileCapabilities(formats: [.init(format: .canvas, operations: [.read: [.notes]])])
        let tool = try #require(FileToolDefinitions.build(capabilities: capabilities, readOnly: true).first)
        let inputs = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(inputs["canvas_node_id"]?.objectValue?["type"]?.stringValue == "string")
        #expect(inputs["canvas_node_id"]?.objectValue?["maxLength"] == nil)
        #expect(Set(inputs["canvas_field"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []) == [
            "text", "file", "subpath", "url", "label", "background",
        ])
        let outputs = try #require(tool.outputSchema?.objectValue?["properties"]?.objectValue)
        #expect(outputs["canvas_node_id"] != nil)
        #expect(outputs["canvas_field"] != nil)
    }

    private func parameters(_ name: String, _ arguments: [String: Value]) throws -> CallTool.Parameters {
        let bytes = try JSONEncoder().encode(CallTool.Parameters(name: name, arguments: arguments))
        return try JSONDecoder().decode(CallTool.Parameters.self, from: bytes)
    }

    private func read(_ controller: FileToolController, _ options: [String: Value]) async throws -> CallTool.Result {
        let identity: [String: Value] = ["format": .string("canvas"), "path": .string("notes/board.canvas")]
        return try await controller.call(try parameters("read_file", identity.merging(options) { _, new in new }))
    }

    private func firstText(_ result: CallTool.Result) throws -> String {
        guard let content = result.content.first, case .text(let text, _, _) = content else {
            throw MissingText()
        }
        return text
    }

    private func node(id: String, type: String, fields: [String: String]) -> [String: Any] {
        var result: [String: Any] = ["id": id, "type": type, "x": 0, "y": 0, "width": 100, "height": 100]
        fields.forEach { result[$0.key] = $0.value }
        return result
    }

    private func document(_ nodes: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["nodes": nodes, "edges": []], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func withFixture(
        _ bytes: Data,
        operation: (VaultRuntime, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasSelectionReadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("references"), withIntermediateDirectories: true)
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: dataDirectory.rootURL)
        }
        try bytes.write(to: root.appendingPathComponent("notes/board.canvas"))
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root.path, readOnly: true)
        try await operation(runtime, root)
    }

    private struct MissingText: Error {}
}
