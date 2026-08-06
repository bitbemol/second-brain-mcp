import Foundation
import MCP
import Testing
@testable import SecondBrainMCP

@Suite("MCP file consistency contract")
struct FileToolContractTests {
    private let capabilities = FileCapabilities(formats: [
        .init(format: .markdown, operations: [
            .create: [.notes],
            .read: [.notes],
            .update: [.notes],
            .delete: [.notes],
        ]),
        .init(format: .json, operations: [
            .create: [.notes],
            .read: [.notes],
            .update: [.notes],
            .delete: [.notes],
        ]),
        .init(format: .csv, operations: [
            .create: [.notes],
            .read: [.notes],
            .update: [.notes],
            .delete: [.notes],
        ]),
        .init(format: .pdf, operations: [
            .read: [.references],
        ]),
    ])

    @Test("The four tools advertise required consistency inputs")
    func inputSchemas() throws {
        let tools = Dictionary(uniqueKeysWithValues: FileToolDefinitions.build(
            capabilities: capabilities,
            readOnly: false
        ).map { ($0.name, $0) })

        #expect(Set(tools.keys) == Set(FileToolName.allCases.map(\.rawValue)))
        #expect(try requiredInputs(of: #require(tools["create_file"])) == [
            "format", "mutation_id", "path",
        ])
        #expect(try requiredInputs(of: #require(tools["read_file"])) == [
            "format", "path",
        ])
        #expect(try requiredInputs(of: #require(tools["update_file"])) == [
            "expected_revision", "format", "mutation_id", "path",
        ])
        #expect(try requiredInputs(of: #require(tools["delete_file"])) == [
            "expected_revision", "format", "mutation_id", "path",
        ])

        let updateProperties = try inputProperties(of: #require(tools["update_file"]))
        #expect(
            updateProperties["expected_revision"]?.objectValue?["pattern"]?.stringValue
                == "^sha256:[0-9a-f]{64}$"
        )
        #expect(
            updateProperties["mutation_id"]?.objectValue?["format"]?.stringValue
                == "uuid"
        )
        let replacementDescription = updateProperties["replacements"]?
            .objectValue?["description"]?.stringValue ?? ""
        #expect(replacementDescription.contains("Markdown"))
        #expect(replacementDescription.contains("JSON"))
        #expect(replacementDescription.contains("CSV"))

        for operation in FileToolName.allCases.map(\.rawValue) {
            let formats = try formatInputs(of: #require(tools[operation]))
            #expect(formats.isSuperset(of: ["json", "csv"]))
        }
    }

    @Test("Structured result schemas expose revision and replay metadata")
    func outputSchemas() throws {
        let tools = Dictionary(uniqueKeysWithValues: FileToolDefinitions.build(
            capabilities: capabilities,
            readOnly: false
        ).map { ($0.name, $0) })

        #expect(try requiredOutputs(of: #require(tools["read_file"])) == [
            "area", "path", "replayed",
        ])
        #expect(try requiredOutputs(of: #require(tools["create_file"])) == [
            "area", "mutation_id", "path", "replayed", "revision",
        ])
        #expect(try requiredOutputs(of: #require(tools["update_file"])) == [
            "area", "mutation_id", "path", "replayed", "revision",
        ])
        #expect(try requiredOutputs(of: #require(tools["delete_file"])) == [
            "area", "mutation_id", "path", "replayed",
        ])

        for operation in ["create_file", "update_file", "delete_file"] {
            #expect(try #require(tools[operation]).annotations.idempotentHint == true)
        }
    }

    @Test("Capabilities describe revisions, compare-and-swap, and durable replay")
    func capabilityResource() throws {
        let result = try FileCapabilitiesResource.read(
            capabilities: capabilities,
            readOnly: false
        )
        let json = try #require(result.contents.first?.text)
        let entries = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        let markdown = try #require(entries.first {
            $0["format"] as? String == "markdown"
        })
        let operations = try #require(markdown["operations"] as? [String: Any])
        let read = try #require(operations["read"] as? [String: Any])
        let create = try #require(operations["create"] as? [String: Any])
        let update = try #require(operations["update"] as? [String: Any])
        let delete = try #require(operations["delete"] as? [String: Any])

        #expect(read["revision_areas"] as? [String] == ["notes"])
        #expect(read["requires_mutation_id"] as? Bool == false)
        #expect(create["create_requires_absence"] as? Bool == true)
        #expect(create["requires_mutation_id"] as? Bool == true)
        #expect(create["durable_replay"] as? Bool == true)
        #expect(update["requires_expected_revision"] as? Bool == true)
        #expect(update["revision_areas"] as? [String] == ["notes"])
        #expect(delete["requires_expected_revision"] as? Bool == true)
        #expect(delete["revision_areas"] as? [String] == [])
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
