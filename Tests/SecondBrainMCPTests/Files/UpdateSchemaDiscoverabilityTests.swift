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
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(Set(properties.keys) == Set(["format", "path", "expected_revision", "mode", "content", "replacements"]))
        let replacements = try #require(properties["replacements"]?.objectValue)
        #expect(replacements["minItems"]?.intValue == 1)
        let items = try #require(replacements["items"]?.objectValue)
        #expect(Set(items["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                == ["old_text", "new_text"])
    }

    @Test("Format conditions expose exactly the catalog-supported modes")
    func formatModesFollowCatalog() throws {
        let schema = try schema()
        let constraints = try #require(schema["allOf"]?.arrayValue)
        var actual: [String: Set<String>] = [:]
        for condition in constraints {
            guard let object = condition.objectValue,
                  let format = object["if"]?.objectValue?["properties"]?.objectValue?["format"]?
                    .objectValue?["const"]?.stringValue else { continue }
            let modes = try #require(object["then"]?.objectValue?["properties"]?.objectValue?["mode"]?
                .objectValue?["enum"]?.arrayValue)
            actual[format] = Set(modes.compactMap(\.stringValue))
        }
        #expect(actual == ["markdown": ["append"], "json": ["patch"]])
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
