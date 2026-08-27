import MCP
import Testing
@testable import second_brain_mcp

/// Durable checks for the advertised schema constraints. Full success/failure
/// examples are additionally exercised through real stdio with a JSON Schema validator.
@Suite
struct DiscoveryOutputSchemaTests {
    @Test
    func coverageSchemaRequiresConsistentFailureFacts() throws {
        for tool in [SearchToolDefinition.build(), LinkQueryToolDefinition.build()] {
            let schema = try #require(tool.outputSchema?.objectValue)
            let coverage = try #require(schema["properties"]?.objectValue?["coverage"]?.objectValue)
            #expect(coverage["required"] == .array([.string("complete")]))
            let alternatives = try #require(coverage["oneOf"]?.arrayValue)
            #expect(alternatives.count == 2)
            let complete = try #require(alternatives.first?.objectValue?["properties"]?.objectValue)
            #expect(complete["complete"] == .object(["const": .bool(true)]))
            for field in ["failed_files", "samples", "samples_truncated"] {
                #expect(complete[field] == .bool(false))
            }
            let incomplete = try #require(alternatives.last?.objectValue)
            #expect(incomplete["properties"]?.objectValue?["complete"] == .object(["const": .bool(false)]))
            #expect(Set(incomplete["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                == Set(["failed_files", "samples", "samples_truncated"]))
        }
    }

    @Test
    func locatorsRequireTheirCompanionFields() throws {
        for (tool, first, second) in [
            (SearchToolDefinition.build(), "canvas_node_id", "canvas_field"),
            (LinkQueryToolDefinition.build(), "resolved_path", "resolved_format"),
        ] {
            let properties = try #require(tool.outputSchema?.objectValue?["properties"]?.objectValue)
            let item = try #require(properties["results"]?.objectValue?["items"]?.objectValue)
            let dependencies = try #require(item["dependentRequired"]?.objectValue)
            #expect(dependencies[first] == .array([.string(second)]))
            #expect(dependencies[second] == .array([.string(first)]))
        }
    }
}
