import Foundation
import MCP
import PDFKit
import Testing
@testable import second_brain_mcp

@Suite
struct `Truthful bounded metadata` {
    @Test
    func `Repeated links do not consume distinct target slots`() async throws {
        let body = String(repeating: "[[same]] ", count: 1_200) + "[[late-distinct]]"
        try await withFixture(Data(body.utf8)) { controller in
            let result = try await readMetadata(controller)
            let facts = try metadata(result)
            #expect(strings(facts["outgoing_link_targets"]) == ["same", "late-distinct"])
            #expect(strings(facts["incomplete_fields"]).isEmpty)
            #expect(facts["incomplete_fields"] != nil)
            print("METADATA_DUPLICATE_TARGETS response_bytes=\(try JSONEncoder().encode(result).count) targets=\(strings(facts["outgoing_link_targets"]).count)")
        }
    }

    @Test
    func `Occurrence work exhaustion is disclosed separately from distinct output limits`() async throws {
        // Matches the existing graph occurrence ceiling, independently of result slots.
        let body = String(repeating: "[[same]] ", count: 100_001) + "[[after-work-ceiling]]"
        try await withFixture(Data(body.utf8)) { controller in
            let facts = try metadata(await readMetadata(controller))
            #expect(strings(facts["outgoing_link_targets"]) == ["same"])
            #expect(strings(facts["incomplete_fields"]) == ["outgoing_link_targets"])
        }
    }

    @Test
    func `Long identifiers are omitted whole and shortened display strings are disclosed`() async throws {
        let longIdentifier = String(repeating: "🧠", count: 300)
        let longTitle = String(repeating: "é", count: 600)
        let text = """
        ---
        title: "\(longTitle)"
        tags: ["ok", "\(longIdentifier)"]
        ---
        [[short.md]] [[\(longIdentifier)]]
        BODY_SENTINEL_MUST_NOT_LEAK
        """
        try await withFixture(Data(text.utf8)) { controller in
            let result = try await readMetadata(controller)
            let facts = try metadata(result)
            #expect(strings(facts["tags"]) == ["ok"])
            #expect(strings(facts["outgoing_link_targets"]) == ["short.md"])
            #expect(Set(strings(facts["incomplete_fields"])) == ["title", "tags", "outgoing_link_targets"])
            let title = try #require(facts["title"]?.stringValue)
            #expect(!title.isEmpty)
            #expect(title.utf8.count <= FileMetadataLimits.maximumStringBytes)
            #expect(longTitle.hasPrefix(title))
            try assertContentFree(result, sentinel: "BODY_SENTINEL_MUST_NOT_LEAK")
            try assertMirroredMetadata(result)
            print("METADATA_LONG_IDENTIFIERS response_bytes=\(try JSONEncoder().encode(result).count)")
        }
    }

    @Test
    func `Distinct collection omissions are explicit and count bounds remain intact`() async throws {
        let tags = (0...FileMetadataLimits.maximumTags).map { "\"tag-\($0)\"" }.joined(separator: ",")
        let links = (0...FileMetadataLimits.maximumOutgoingLinks).map { "[[target-\($0)]]" }.joined(separator: " ")
        let text = "---\ntags: [\(tags)]\n---\n\(links)"
        try await withFixture(Data(text.utf8)) { controller in
            let result = try await readMetadata(controller)
            let facts = try metadata(result)
            #expect(strings(facts["tags"]).count == FileMetadataLimits.maximumTags)
            #expect(strings(facts["outgoing_link_targets"]).count == FileMetadataLimits.maximumOutgoingLinks)
            #expect(Set(strings(facts["incomplete_fields"])) == ["tags", "outgoing_link_targets"])
            #expect(facts["total_links"] == nil)
            #expect(facts["total_tags"] == nil)
        }
    }

    @Test
    func `Target byte budgets omit exact targets without fabricating prefixes`() async throws {
        let targets = (0..<80).map { String(repeating: "a", count: 900) + "-\($0).md" }
        let text = targets.map { "[[\($0)]]" }.joined(separator: " ")
        try await withFixture(Data(text.utf8)) { controller in
            let result = try await readMetadata(controller)
            let facts = try metadata(result)
            let returned = strings(facts["outgoing_link_targets"])
            #expect(!returned.isEmpty)
            #expect(returned.count < targets.count)
            #expect(returned.reduce(0) { $0 + $1.utf8.count } <= FileMetadataLimits.maximumOutgoingLinkBytes)
            #expect(returned.allSatisfy { targets.contains($0) })
            #expect(strings(facts["incomplete_fields"]) == ["outgoing_link_targets"])
        }
    }

    @Test
    func `Metadata and graph share local inline wiki and code exclusion grammar`() async throws {
        let text = #"""
        [[Wiki#Section|Alias]] ![[figure.png]]
        [inline](path/to.md#Heading) [space](<Folder/My%20Note.md>) ![image](images/pic.png)
        [same-page](#Heading)
        [[Meeting:Notes]] [[https://example.invalid/]] [[file:/outside]] [[custom://host]]
        `[[inline-code]]`
        ```
        [[fenced-code]]
        [fenced](also-code.md)
        ```
        \[[escaped]]
        [web](https://example.invalid/) [mail](mailto:agent@example.invalid)
        [data](data:text/plain,hello) [other](custom-scheme:value)
        """#
        try await withFixture(Data(text.utf8)) { controller in
            let result = try await readMetadata(controller)
            let facts = try metadata(result)
            #expect(strings(facts["outgoing_link_targets"]) == [
                "Wiki#Section", "figure.png", "path/to.md#Heading",
                "Folder/My%20Note.md", "images/pic.png", "#Heading", "Meeting:Notes",
            ])
            #expect(strings(facts["incomplete_fields"]).isEmpty)
        }
    }

    @Test
    func `PDF display and collection truncation identify each incomplete field without page content`() async throws {
        let data = metadataPDF(pageCount: 513, outlineCount: 257)
        let reopened = try #require(PDFDocument(data: data))
        try #require(reopened.pageCount == 513)
        try #require(reopened.outlineRoot?.numberOfChildren == 257)
        try await withFixture(data, format: .pdf) { controller in
            let result = try await readMetadata(controller, format: .pdf)
            let facts = try metadata(result)
            #expect(Set(strings(facts["incomplete_fields"])) == ["title", "author", "page_labels", "outline"])
            #expect(facts["title"]?.stringValue?.utf8.count == FileMetadataLimits.maximumStringBytes)
            #expect(facts["author"]?.stringValue?.utf8.count == FileMetadataLimits.maximumStringBytes)
            #expect(strings(facts["page_labels"]).count == FileMetadataLimits.maximumPDFPageLabels)
            #expect(facts["outline"]?.arrayValue?.count == FileMetadataLimits.maximumPDFOutlineEntries)
            #expect(facts["page_labels_truncated"]?.boolValue == true)
            #expect(facts["outline_truncated"]?.boolValue == true)
            try assertContentFree(result, sentinel: "PDF_PAGE_SENTINEL_MUST_NOT_LEAK")
            try assertMirroredMetadata(result)
        }
    }

    @Test
    func `PDF display shortening is disclosed even when every collection entry fits`() async throws {
        let data = metadataPDF(pageCount: 1, outlineCount: 1)
        let reopened = try #require(PDFDocument(data: data))
        try #require(reopened.outlineRoot?.numberOfChildren == 1)
        try #require((reopened.page(at: 0)?.label?.utf8.count ?? 0) > 1_024)
        try await withFixture(data, format: .pdf) { controller in
            let result = try await readMetadata(controller, format: .pdf)
            let facts = try metadata(result)
            #expect(Set(strings(facts["incomplete_fields"])) == ["title", "author", "page_labels", "outline"])
            #expect(facts["page_labels_truncated"]?.boolValue == false)
            #expect(facts["outline_truncated"]?.boolValue == false)
            let label = try #require(facts["page_labels"]?.arrayValue?.first?.stringValue)
            #expect(label.utf8.count == FileMetadataLimits.maximumStringBytes)
            try assertContentFree(result, sentinel: "PDF_PAGE_SENTINEL_MUST_NOT_LEAK")
        }
    }

    @Test
    func `Metadata schemas advertise bounded completeness and collection limits`() throws {
        let tool = try #require(FileToolDefinitions.build(
            capabilities: FileCapabilities(formats: [.init(format: .markdown, operations: [.read: [.notes]])]),
            readOnly: true
        ).first)
        let schema = try #require(tool.outputSchema?.objectValue?["properties"]?.objectValue?["metadata"]?.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)
        let incomplete = try #require(properties["incomplete_fields"]?.objectValue)
        #expect(incomplete["maxItems"]?.intValue == 6)
        #expect(incomplete["uniqueItems"]?.boolValue == true)
        #expect(Set(strings(incomplete["items"]?.objectValue?["enum"])) == [
            "title", "tags", "outgoing_link_targets", "author", "page_labels", "outline",
        ])
        #expect(strings(schema["required"]).contains("incomplete_fields"))
        #expect(properties["tags"]?.objectValue?["maxItems"]?.intValue == FileMetadataLimits.maximumTags)
        #expect(properties["outgoing_link_targets"]?.objectValue?["maxItems"]?.intValue == FileMetadataLimits.maximumOutgoingLinks)
        #expect(properties["page_labels"]?.objectValue?["maxItems"]?.intValue == FileMetadataLimits.maximumPDFPageLabels)
        #expect(properties["outline"]?.objectValue?["maxItems"]?.intValue == FileMetadataLimits.maximumPDFOutlineEntries)
    }

    @Test("Metadata errors name only the conflicting supplied selector")
    func metadataConflictNamesProvidedSelector() async throws {
        let selectors: [String: Value] = [
            "tail_lines": .int(1), "start_line": .int(1), "max_lines": .int(1),
            "page": .int(1), "pages": .array([.int(1)]), "page_range": .string("1-2"),
            "byte_offset": .int(0), "max_bytes": .int(65_536),
            "expected_revision": .string("sha256:" + String(repeating: "a", count: 64)),
        ]
        try await withFixture(Data("# Safe metadata\nBODY_NOT_FOR_ERRORS".utf8)) { controller in
            for (selector, value) in selectors {
                let result = try await controller.call(.init(name: "read_file", arguments: [
                    "format": .string("markdown"), "path": .string("notes/note.md"),
                    "view": .string("metadata"), selector: value,
                ]))
                let message = result.content.compactMap { content -> String? in
                    if case .text(let text, _, _) = content { return text }
                    return nil
                }.joined()
                #expect(result.isError == true)
                #expect(message.contains(selector))
                #expect(message.lowercased().contains("omit"))
                #expect(message.contains("view=content"))
                let mentioned = Set(message.split {
                    !$0.isLetter && !$0.isNumber && $0 != "_"
                }.map(String.init)).intersection(selectors.keys)
                #expect(mentioned == [selector])
                #expect(message.utf8.count <= 512)
                #expect(!message.contains("BODY_NOT_FOR_ERRORS"))
            }
            // The valid repair must still return metadata, never a body.
            let repaired = try await readMetadata(controller)
            _ = try metadata(repaired)
            try assertContentFree(repaired, sentinel: "BODY_NOT_FOR_ERRORS")
        }
    }

    @Test("Metadata errors report every conflict without echoing selector values")
    func metadataConflictNamesAllProvidedSelectors() async throws {
        try await withFixture(Data("safe note".utf8)) { controller in
            let marker = "PRIVATE_SELECTOR_VALUE"
            let result = try await controller.call(.init(name: "read_file", arguments: [
                "format": .string("markdown"), "path": .string("notes/note.md"),
                "view": .string("metadata"), "max_bytes": .int(65_536),
                "byte_offset": .int(0), "page_range": .string(marker),
                "expected_revision": .string("sha256:" + String(repeating: "a", count: 64)),
            ]))
            let message = result.content.compactMap { content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }.joined()
            #expect(result.isError == true)
            for field in ["max_bytes", "byte_offset", "page_range", "expected_revision"] {
                #expect(message.contains(field))
            }
            #expect(message.lowercased().contains("omit"))
            #expect(message.contains("view=content"))
            #expect(!message.contains(marker))
            #expect(message.utf8.count <= 512)
        }
    }

    private func readMetadata(_ controller: FileToolController, format: FileFormat = .markdown) async throws -> CallTool.Result {
        let path = format == .pdf ? "references/manual.pdf" : "notes/note.md"
        let parameters = CallTool.Parameters(name: "read_file", arguments: [
            "format": .string(format.rawValue), "path": .string(path), "view": .string("metadata"),
        ])
        let bytes = try JSONEncoder().encode(parameters)
        return try await controller.call(JSONDecoder().decode(CallTool.Parameters.self, from: bytes))
    }

    private func metadata(_ result: CallTool.Result) throws -> [String: Value] {
        try #require(result.isError != true)
        return try #require(result.structuredContent?.objectValue?["metadata"]?.objectValue)
    }

    private func strings(_ value: Value?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func assertContentFree(_ result: CallTool.Result, sentinel: String) throws {
        let encoded = try JSONEncoder().encode(result)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(sentinel))
        for content in result.content {
            guard case .text = content else {
                Issue.record("Metadata must not include image or other content blocks")
                continue
            }
        }
        #expect(result.structuredContent?.objectValue?["text_window"] == nil)
    }

    private func assertMirroredMetadata(_ result: CallTool.Result) throws {
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else {
            Issue.record("Expected content-free JSON metadata for text-only clients")
            return
        }
        let mirrored = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        #expect(mirrored == result.structuredContent?.objectValue?["metadata"])
    }

    /// Emits a minimal exact PDF instead of depending on PDFKit's outline writer.
    private func metadataPDF(pageCount: Int, outlineCount: Int) -> Data {
        let firstPage = 7
        let firstOutline = firstPage + pageCount
        let pageIDs = (0..<pageCount).map { "\($0 + firstPage) 0 R" }.joined(separator: " ")
        let content = "BT /F1 12 Tf 12 100 Td (PDF_PAGE_SENTINEL_MUST_NOT_LEAK) Tj ET"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R /PageLabels << /Nums [0 << /P (\(String(repeating: "P", count: 1_100))) /S /D >>] >> >>",
            "<< /Type /Pages /Kids [\(pageIDs)] /Count \(pageCount) >>",
            "<< /Title (\(String(repeating: "T", count: 1_100))) /Author (\(String(repeating: "A", count: 1_100))) >>",
            "<< /Type /Outlines /First \(firstOutline) 0 R /Last \(firstOutline + outlineCount - 1) 0 R /Count \(outlineCount) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        for _ in 0..<pageCount {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        }
        for index in 0..<outlineCount {
            let previous = index > 0 ? "/Prev \(firstOutline + index - 1) 0 R" : ""
            let next = index + 1 < outlineCount ? "/Next \(firstOutline + index + 1) 0 R" : ""
            let label = index == 0 ? String(repeating: "L", count: 1_100) : "Entry \(index)"
            objects.append("<< /Title (\(label)) /Parent 4 0 R /Dest [\(firstPage) 0 R /XYZ 0 0 0] \(previous) \(next) >>")
        }
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010ld 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func withFixture(
        _ data: Data,
        format: FileFormat = .markdown,
        operation: (FileToolController) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileMetadataCompletenessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("references"), withIntermediateDirectories: true)
        let support = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: support.rootURL)
        }
        let path = format == .pdf ? "references/manual.pdf" : "notes/note.md"
        try data.write(to: root.appendingPathComponent(path))
        let runtime = try await VaultRuntime.bootstrap(vaultPath: root.path, readOnly: true)
        try await operation(FileToolController(readOnly: true, files: runtime.files))
    }
}
