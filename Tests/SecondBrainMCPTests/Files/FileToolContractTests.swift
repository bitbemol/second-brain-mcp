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
            "expected_revision", "format", "path",
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
        let readProperties = try inputProperties(of: #require(tools["read_file"]))
        #expect(readProperties["query"] == nil)
        #expect(
            readProperties["book_page"]?.objectValue?["maxLength"]?.intValue
                == FileReadRequestLimits.maximumPDFBookPageBytes
        )
        #expect(
            readProperties["page_range"]?.objectValue?["maxLength"]?.intValue
                == FileReadRequestLimits.maximumPDFPageRangeBytes
        )

        for operation in FileToolName.allCases.map(\.rawValue) {
            let formats = try formatInputs(of: #require(tools[operation]))
            #expect(formats.isSuperset(of: ["json", "csv"]))
        }
    }

    @Test
    func `Structured result schemas expose only path area and revisions`() throws {
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

        for operation in ["create_file", "update_file", "delete_file"] {
            #expect(try #require(tools[operation]).annotations.idempotentHint != true)
        }
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
}
