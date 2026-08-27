import MCP

/// Builds one bounded, locator-only Obsidian link graph query.
enum LinkQueryToolDefinition {
    static let name = "query_links"

    static func build() -> Tool {
        Tool(
            name: name,
            description: "Resolve one Obsidian wiki-link target, enumerate outgoing links from one Markdown note, or find backlinks to a target. Supports aliases, embeds, extensionless Markdown names, explicit paths, and optional from_path proximity. Results are bounded structured locators without snippets or file content. Continue with next_cursor until absent; restart without it if the vault changed.",
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
                        "description": .string("Opaque next_cursor from an identical preceding request; restart without it if stale"),
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
                                "description": .string("Wiki-link target text as written or queried"),
                            ]),
                            "resolved_path": .object([
                                "type": .string("string"),
                                "description": .string("Resolved vault-relative Markdown path when resolution succeeded"),
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
                                "description": .string("Optional display alias from the wiki-link"),
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
                        "required": .array([
                            .string("target"), .string("kind"), .string("ambiguous"),
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
            "required": .array([.string("direction"), .string("results")]),
            "additionalProperties": .bool(false),
        ])
    }
}
