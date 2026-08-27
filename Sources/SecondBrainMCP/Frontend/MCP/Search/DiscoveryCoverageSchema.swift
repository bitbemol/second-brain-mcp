import MCP

/// One shared wire contract for discovery completeness, independent of pagination.
enum DiscoveryCoverageSchema {
    static let value: Value = .object([
        "type": .string("object"),
        "description": .string("Whether every eligible source was examined; incomplete coverage cannot establish absence"),
        "properties": .object([
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
        ]),
        "required": .array([.string("complete")]),
        "oneOf": .array([
            .object([
                "properties": .object([
                    "complete": .object(["const": .bool(true)]),
                    "failed_files": .bool(false), "samples": .bool(false),
                    "samples_truncated": .bool(false),
                ]),
            ]),
            .object([
                "properties": .object(["complete": .object(["const": .bool(false)])]),
                "required": .array([
                    .string("failed_files"), .string("samples"), .string("samples_truncated"),
                ]),
            ]),
        ]),
        "additionalProperties": .bool(false),
    ])
}
