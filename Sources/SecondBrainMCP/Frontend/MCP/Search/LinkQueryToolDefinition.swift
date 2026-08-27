import MCP

/// Builds one bounded, locator-only Obsidian link graph query.
enum LinkQueryToolDefinition {
    static let name = "query_links"

    static func build() -> Tool {
        Tool(
            name: name,
            description: "Resolve one Obsidian wiki-link target, enumerate wiki and inline Markdown links/images from one note (excluding code, escapes, external URLs and unsupported reference-style links), or find backlinks to a target. Backlinks default to one source/target pair with occurrence_count; use group_by=occurrence and source_path for precise drill-down. Results contain locators, not snippets. coverage.complete=false means some sources failed: do not infer absence. next_cursor paginates examined results; keep criteria unchanged, but limit may change. Restart a stale cursor.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    LinkQueryToolArgument.direction.rawValue: .object([
                        "type": .string("string"),
                        "enum": .array(LinkQueryDirection.allCases.map {
                            .string($0.rawValue)
                        }),
                        "description": .string("resolve returns target candidates, outgoing enumerates links in one source note, and backlinks finds notes linking to a target"),
                    ]),
                    LinkQueryToolArgument.target.rawValue: .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "maxLength": .int(LinkQueryLimits.maximumTargetBytes),
                        "description": .string("Wiki target, or notes/...md source path for outgoing"),
                    ]),
                    LinkQueryToolArgument.fromPath.rawValue: .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "maxLength": .int(LinkQueryLimits.maximumTargetBytes),
                        "description": .string("Existing Markdown note used only for proximity and ambiguity resolution"),
                    ]),
                    LinkQueryToolArgument.groupBy.rawValue: .object([
                        "type": .string("string"),
                        "enum": .array(LinkQueryGrouping.allCases.map { .string($0.rawValue) }),
                        "description": .string("Backlinks only: source (default) groups each source/target pair; occurrence preserves individual links. Omit for other directions."),
                    ]),
                    LinkQueryToolArgument.sourcePath.rawValue: .object([
                        "type": .string("string"),
                        "minLength": .int(1), "maxLength": .int(LinkQueryLimits.maximumTargetBytes),
                        "description": .string("Backlinks only: examine this one notes/...md source for selected-group drill-down"),
                    ]),
                    LinkQueryToolArgument.limit.rawValue: .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(LinkQueryLimits.maximumResults),
                        "default": .int(LinkQueryLimits.defaultResults),
                        "description": .string("Maximum link locators or resolution candidates to return in this page"),
                    ]),
                    LinkQueryToolArgument.cursor.rawValue: .object([
                        "type": .string("string"),
                        "maxLength": .int(LinkQueryLimits.maximumCursorBytes),
                        "description": .string("Opaque next_cursor with unchanged semantic criteria; limit may change. Restart without it if stale"),
                    ]),
                ]),
                "required": .array([
                    .string(LinkQueryToolArgument.direction.rawValue),
                    .string(LinkQueryToolArgument.target.rawValue),
                ]),
                "additionalProperties": .bool(false),
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            ),
            outputSchema: outputSchema()
        )
    }

    private static func outputSchema() -> Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "direction": .object([
                    "type": .string("string"),
                    "enum": .array(LinkQueryDirection.allCases.map {
                        .string($0.rawValue)
                    }),
                    "description": .string("Direction executed for these results"),
                ]),
                "coverage": DiscoveryCoverageSchema.value,
                "results": .object([
                    "type": .string("array"),
                    "maxItems": .int(LinkQueryLimits.maximumResults),
                    "description": .string("Bounded link locators or resolution candidates without snippets or file content"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "source_path": .object([
                                "type": .string("string"),
                                "description": .string("Vault-relative Markdown note containing the link, when the direction has a source"),
                            ]),
                            "target": .object([
                                "type": .string("string"),
                                "description": .string("Raw local-link target as written or queried, including its fragment"),
                            ]),
                            "resolved_path": .object([
                                "type": .string("string"),
                                "description": .string("Resolved vault-relative path when resolution succeeded"),
                            ]),
                            "resolved_format": .object([
                                "type": .string("string"),
                                "enum": .array(FileFormat.allCases.map { .string($0.rawValue) }),
                                "description": .string("Concrete format for read_file, paired with resolved_path"),
                            ]),
                            "occurrence_count": .object([
                                "type": .string("integer"), "minimum": .int(1),
                                "description": .string("Source-group count of distinct contributing occurrences"),
                            ]),
                            "kind": .object([
                                "type": .string("string"),
                                "enum": .array([VaultWikiLinkKind.link, .embed].map {
                                    .string($0.rawValue)
                                }),
                                "description": .string("Whether the occurrence is a link or embed"),
                            ]),
                            "alias": .object([
                                "type": .string("string"),
                                "description": .string("Optional wiki display alias or inline Markdown link label"),
                            ]),
                            "fragment": .object([
                                "type": .string("string"),
                                "description": .string("Fragment text without its leading # or ^ delimiter"),
                            ]),
                            "occurrence": .object([
                                "type": .string("integer"),
                                "minimum": .int(1),
                                "description": .string("One-based occurrence index within the source note"),
                            ]),
                            "ambiguous": .object([
                                "type": .string("boolean"),
                                "description": .string("True when the target maps to multiple candidate paths"),
                            ]),
                        ]),
                        "required": .array([.string("ambiguous")]),
                        "dependentRequired": .object([
                            "resolved_path": .array([.string("resolved_format")]),
                            "resolved_format": .array([.string("resolved_path")]),
                        ]),
                        "oneOf": .array([
                            .object([
                                "required": .array([
                                    .string("source_path"), .string("resolved_path"),
                                    .string("resolved_format"), .string("occurrence_count"),
                                ]),
                                "properties": .object([
                                    "target": .bool(false), "kind": .bool(false),
                                    "alias": .bool(false), "occurrence": .bool(false),
                                    "fragment": .bool(false),
                                ]),
                            ]),
                            .object([
                                "required": .array([.string("target"), .string("kind")]),
                                "properties": .object(["occurrence_count": .bool(false)]),
                            ]),
                        ]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "next_cursor": .object([
                    "type": .string("string"),
                    "maxLength": .int(LinkQueryLimits.maximumCursorBytes),
                    "description": .string("Opaque continuation cursor; absent only when this query is exhausted"),
                ]),
            ]),
            "required": .array([.string("direction"), .string("results"), .string("coverage")]),
            "additionalProperties": .bool(false),
        ])
    }
}
