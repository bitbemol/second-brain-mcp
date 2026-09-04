import MCP
import Testing
@testable import second_brain_mcp

@Suite("Update schema discoverability")
struct UpdateSchemaDiscoverabilityTests {
    @Test("Callable update fields remain flat instead of a root union")
    func fieldsAreVisible() throws {
        let schema = try schema()
        #expect(schema["oneOf"] == nil)
        #expect(schema["anyOf"] == nil)
        #expect(schema["allOf"] == nil)
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(Set(properties.keys) == Set(["format", "path", "expected_revision", "mode", "content", "replacements"]))
        let replacements = try #require(properties["replacements"]?.objectValue)
        #expect(replacements["minItems"]?.intValue == 1)
        let items = try #require(replacements["items"]?.objectValue)
        #expect(Set(items["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                == ["old_text", "new_text"])
    }

    @Test("Descriptions expose catalog-supported modes and conditional inputs")
    func formatModesFollowCatalog() throws {
        let schema = try schema()
        let description = try #require(schema["properties"]?.objectValue?["mode"]?
            .objectValue?["description"]?.stringValue)
        #expect(description.contains("markdown=append"))
        #expect(description.contains("json=patch"))
        #expect(!description.contains("png="))
        #expect(!description.contains("markdown=append|"))
        #expect(!description.contains("json=patch|"))
        #expect(description.contains("patch requires replacements and forbids content"))
        #expect(description.contains("replace and append require content and forbid replacements"))
        let formats = schema["properties"]?.objectValue?["format"]?.objectValue?["enum"]?
            .arrayValue?.compactMap(\.stringValue)
        #expect(Set(formats ?? []) == ["markdown", "json"])
    }

    private func schema() throws -> [String: Value] {
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.update: [.notes]], updateModes: [.append]),
            .init(format: .json, operations: [.update: [.notes]], updateModes: [.patch]),
            .init(format: .png, operations: [.read: [.notes]]),
        ])
        let tool = try #require(FileToolDefinitions.build(capabilities: capabilities, readOnly: false)
            .first { $0.name == "update_file" })
        return try #require(tool.inputSchema.objectValue)
    }
}
