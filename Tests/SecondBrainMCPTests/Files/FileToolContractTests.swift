import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite
struct `MCP file consistency contract` {
    private let capabilities = FileCapabilities(formats: [
        .init(
            format: .markdown,
            operations: [
                .create: [.notes],
                .read: [.notes],
                .update: [.notes],
                .delete: [.notes],
            ],
            createContract: FileCreateContract(
                input: .content,
                transform: nil,
                acceptsTags: true
            ),
            updateModes: Set(FileUpdateMode.allCases)
        ),
        .init(
            format: .json,
            operations: [
                .create: [.notes],
                .read: [.notes],
                .update: [.notes],
                .delete: [.notes],
            ],
            createContract: .content,
            updateModes: [.replace, .patch]
        ),
        .init(
            format: .csv,
            operations: [
                .create: [.notes],
                .read: [.notes],
                .update: [.notes],
                .delete: [.notes],
            ],
            createContract: .content,
            updateModes: Set(FileUpdateMode.allCases)
        ),
        .init(format: .pdf, operations: [
            .read: [.references],
        ]),
    ])

    @Test
    func `The four tools advertise required consistency inputs`() throws {
        let tools = Dictionary(uniqueKeysWithValues: FileToolDefinitions.build(
            capabilities: capabilities,
            readOnly: false
        ).map { ($0.name, $0) })

        #expect(Set(tools.keys) == Set(FileToolName.allCases.map(\.rawValue)))
        #expect(try requiredInputs(of: #require(tools["create_file"])) == [
            "format", "path",
        ])
        #expect(try requiredInputs(of: #require(tools["read_file"])) == [
            "format", "path",
        ])
        #expect(try requiredInputs(of: #require(tools["update_file"])) == [
            "expected_revision", "format", "mode", "path",
        ])
        #expect(try requiredInputs(of: #require(tools["delete_file"])) == [
            "expected_revision", "format", "path",
        ])

        let updateProperties = try inputProperties(of: #require(tools["update_file"]))
        #expect(
            updateProperties["expected_revision"]?.objectValue?["pattern"]?.stringValue
                == "^sha256:[0-9a-f]{64}$"
        )
        #expect(updateProperties["mutation_id"] == nil)
        let replacementDescription = updateProperties["replacements"]?
            .objectValue?["description"]?.stringValue ?? ""
        #expect(replacementDescription.contains("markdown"))
        #expect(replacementDescription.contains("json"))
        #expect(replacementDescription.contains("csv"))
        let readTool = try #require(tools["read_file"])
        let readSchema = try #require(readTool.inputSchema.objectValue)
        #expect(readSchema["additionalProperties"]?.boolValue == false)
        let readProperties = try inputProperties(of: readTool)
        #expect(readProperties["query"] == nil)
        #expect(readProperties["book_page"] == nil)
        #expect(readProperties["max_pages"] == nil)
        #expect(
            readProperties["pages"]?.objectValue?["maxItems"]?.intValue == 20
        )
        #expect(
            readProperties["pages"]?.objectValue?["uniqueItems"]?.boolValue == true
        )
        #expect(
            readProperties["page_range"]?.objectValue?["maxLength"]?.intValue
                == FileReadRequestLimits.maximumPDFPageRangeBytes
        )
        #expect(
            readProperties["byte_offset"]?.objectValue?["minimum"]?.intValue == 0
        )
        #expect(
            readProperties["max_bytes"]?.objectValue?["default"]?.intValue
                == FileReadRequestLimits.defaultTextChunkBytes
        )
        #expect(
            readProperties["max_bytes"]?.objectValue?["maximum"]?.intValue
                == FileReadRequestLimits.maximumTextChunkBytes
        )
        #expect(
            readProperties["expected_revision"]?.objectValue?["pattern"]?.stringValue
                == "^sha256:[0-9a-f]{64}$"
        )

        for operation in FileToolName.allCases.map(\.rawValue) {
            let formats = try formatInputs(of: #require(tools[operation]))
            #expect(formats.isSuperset(of: ["json", "csv"]))
        }
    }

    @Test
    func `Structured result schemas expose identity revisions and optional text windows`() throws {
        let tools = Dictionary(uniqueKeysWithValues: FileToolDefinitions.build(
            capabilities: capabilities,
            readOnly: false
        ).map { ($0.name, $0) })

        #expect(try requiredOutputs(of: #require(tools["read_file"])) == [
            "area", "path",
        ])
        #expect(try requiredOutputs(of: #require(tools["create_file"])) == [
            "area", "path", "revision",
        ])
        #expect(try requiredOutputs(of: #require(tools["update_file"])) == [
            "area", "path", "revision",
        ])
        #expect(try requiredOutputs(of: #require(tools["delete_file"])) == [
            "area", "path",
        ])
        #expect(Set(try outputProperties(of: #require(tools["create_file"])).keys) == [
            "area", "path", "revision",
        ])
        #expect(Set(try outputProperties(of: #require(tools["read_file"])).keys) == [
            "area", "metadata", "path", "revision", "text_window",
        ])
        #expect(Set(try outputProperties(of: #require(tools["update_file"])).keys) == [
            "area", "path", "revision",
        ])
        #expect(Set(try outputProperties(of: #require(tools["delete_file"])).keys) == [
            "area", "path",
        ])
        let readOutput = try #require(tools["read_file"]?.outputSchema?.objectValue)
        let readOutputProperties = try #require(
            readOutput["properties"]?.objectValue
        )
        let textWindow = try #require(
            readOutputProperties["text_window"]?.objectValue
        )
        #expect(textWindow["additionalProperties"]?.boolValue == false)
        #expect(
            textWindow["required"]?.arrayValue?.compactMap(\.stringValue).sorted()
                == ["byte_count", "byte_offset", "total_bytes"]
        )

        for operation in ["create_file", "update_file", "delete_file"] {
            #expect(try #require(tools[operation]).annotations.idempotentHint != true)
        }
    }

    @Test
    func `File schemas explain every top level input and structured output field`() throws {
        let tools = FileToolDefinitions.build(capabilities: capabilities, readOnly: false)
        for tool in tools {
            let input = try inputProperties(of: tool)
            let output = try outputProperties(of: tool)
            #expect(describedKeys(input) == Set(input.keys))
            #expect(describedKeys(output) == Set(output.keys))
        }

        let read = try #require(tools.first { $0.name == "read_file" })
        let readOutput = try outputProperties(of: read)
        let metadata = try #require(readOutput["metadata"]?.objectValue?["properties"]?.objectValue)
        let textWindow = try #require(readOutput["text_window"]?.objectValue?["properties"]?.objectValue)
        #expect(describedKeys(metadata) == Set(metadata.keys))
        #expect(describedKeys(textWindow) == Set(textWindow.keys))

        let outline = try #require(
            metadata["outline"]?.objectValue?["items"]?
                .objectValue?["properties"]?.objectValue
        )
        #expect(describedKeys(outline) == Set(outline.keys))

        let move = try #require(PathMoveToolDefinition.build(
            readOnly: false,
            capabilities: capabilities
        ))
        let moveOutput = try outputProperties(of: move)
        #expect(describedKeys(moveOutput) == Set(moveOutput.keys))
    }

    @Test
    func `List files advertises bounded criteria-free discovery`() throws {
        let tool = ListFilesToolDefinition.build(capabilities: capabilities)
        #expect(tool.name == "list_files")
        #expect(try requiredInputs(of: tool) == ["area"])
        let properties = try inputProperties(of: tool)
        #expect(properties["directory"]?.objectValue?["maxLength"]?.intValue
            == FileListingRequestLimits.maximumDirectoryBytes)
        #expect(properties["recursive"]?.objectValue?["default"]?.boolValue == true)
        #expect(properties["limit"]?.objectValue?["maximum"]?.intValue
            == FileListingRequestLimits.maximumResults)
        #expect(properties["cursor"]?.objectValue?["maxLength"]?.intValue
            == FileListingRequestLimits.maximumCursorBytes)
        #expect(tool.annotations.readOnlyHint == true)
        #expect(tool.annotations.openWorldHint == false)
    }

    private func requiredInputs(of tool: MCP.Tool) throws -> [String] {
        let schema = try #require(tool.inputSchema.objectValue)
        return try #require(schema["required"]?.arrayValue)
            .compactMap(\.stringValue)
            .sorted()
    }

    private func inputProperties(of tool: MCP.Tool) throws -> [String: MCP.Value] {
        let schema = try #require(tool.inputSchema.objectValue)
        return try #require(schema["properties"]?.objectValue)
    }

    private func formatInputs(of tool: MCP.Tool) throws -> Set<String> {
        let properties = try inputProperties(of: tool)
        let format = try #require(properties["format"]?.objectValue)
        return Set(try #require(format["enum"]?.arrayValue).compactMap(\.stringValue))
    }

    private func requiredOutputs(of tool: MCP.Tool) throws -> [String] {
        let schema = try #require(tool.outputSchema?.objectValue)
        return try #require(schema["required"]?.arrayValue)
            .compactMap(\.stringValue)
            .sorted()
    }

    private func outputProperties(of tool: MCP.Tool) throws -> [String: MCP.Value] {
        let schema = try #require(tool.outputSchema?.objectValue)
        return try #require(schema["properties"]?.objectValue)
    }

    private func describedKeys(_ properties: [String: MCP.Value]) -> Set<String> {
        Set(properties.compactMap { key, value in
            guard let description = value.objectValue?["description"]?.stringValue,
                  !description.isEmpty else {
                return nil
            }
            return key
        })
    }
}
