import MCP

/// Common completeness fields, with bounded format counts only for content search.
enum DiscoveryCoverageSchema {
    static let value = build(includeFormatCounts: false)
    static let searchValue = build(includeFormatCounts: true)

    private static func build(includeFormatCounts: Bool) -> Value {
        var properties: [String: Value] = [
            "complete": .object([
                "type": .string("boolean"),
                "description": .string("True only when the entire eligible scope was successfully examined"),
            ]),
            "failed_files": .object([
                "type": .string("integer"), "minimum": .int(1),
                "description": .string("Exact count of isolated source failures when coverage is incomplete"),
            ]),
            "samples": .object([
                "type": .string("array"), "maxItems": .int(3),
                "description": .string("At most three whole relative paths and safe categories, within a 2048-byte coverage budget"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "reason": .object([
                            "type": .string("string"),
                            "enum": .array(DiscoveryCoverage.Reason.allCases.map { .string($0.rawValue) }),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("reason")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "samples_truncated": .object([
                "type": .string("boolean"),
                "description": .string("True when additional failed-source samples were omitted"),
            ]),
        ]
        var completeProperties: [String: Value] = [
            "complete": .object(["const": .bool(true)]),
            "failed_files": .bool(false), "samples": .bool(false),
            "samples_truncated": .bool(false),
        ]
        var incompleteRequired: [Value] = [
            .string("failed_files"), .string("samples"), .string("samples_truncated"),
        ]
        if includeFormatCounts {
            properties["failed_by_format"] = .object([
                "type": .string("object"),
                "description": .string("Exact failed-file counts by concrete format, including failures omitted from samples; sum equals failed_files"),
                "minProperties": .int(1),
                "maxProperties": .int(FileFormat.allCases.count),
                "propertyNames": .object([
                    "enum": .array(FileFormat.allCases.map { .string($0.rawValue) }),
                ]),
                "additionalProperties": .object([
                    "type": .string("integer"), "minimum": .int(1),
                    "maximum": .int(SearchRequestLimits.maximumIndexedFiles),
                ]),
            ])
            completeProperties["failed_by_format"] = .bool(false)
            incompleteRequired.append(.string("failed_by_format"))
        }
        return .object([
            "type": .string("object"),
            "description": .string("Whether every eligible source was examined; incomplete coverage cannot establish absence"),
            "properties": .object(properties),
            "required": .array([.string("complete")]),
            "oneOf": .array([
                .object(["properties": .object(completeProperties)]),
                .object([
                    "properties": .object(["complete": .object(["const": .bool(false)])]),
                    "required": .array(incompleteRequired),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    }
}
