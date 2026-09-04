import MCP

/// Public contract for one atomic notes file or directory rename.
enum PathMoveToolDefinition {
    static let name = MovePathRequest.operationIdentifier

    /// Builds the mutation tool unless the server is read-only.
    static func build(
        readOnly: Bool,
        capabilities: FileCapabilities
    ) -> Tool? {
        guard !readOnly else { return nil }
        let formats = capabilities
            .supportedFormats(for: .delete, in: .notes)
            .map { Value.string($0.rawValue) }
        return Tool(
            name: name,
            description: "Move or rename exactly one existing path under notes/ without rewriting its bytes. Choose kind=file for one supported file and provide the same concrete format plus expected_revision returned by read_file; stale revisions are rejected. Choose kind=directory for one complete subtree and omit format and expected_revision. Both variants are atomic, never overwrite destination_path, preserve nested content, and request one Git snapshot. Use this instead of read-create-delete, which is non-atomic and may change bytes. This tool does not batch moves.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array(PathMoveKind.allCases.map { .string($0.rawValue) }),
                        "description": .string("file moves one supported file; directory moves a complete subtree"),
                    ]),
                    "source_path": pathSchema("Existing source under notes/"),
                    "destination_path": pathSchema("Exact unused destination under notes/"),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array(formats),
                        "description": .string("Required for kind=file; omit for kind=directory. Concrete source and destination format; both extensions must match."),
                    ]),
                    "expected_revision": .object([
                        "type": .string("string"),
                        "pattern": .string("^sha256:[0-9a-f]{64}$"),
                        "description": .string("Required for kind=file; omit for kind=directory. Exact revision returned by read_file for source_path."),
                    ]),
                ]),
                "required": .array([
                    .string("kind"), .string("source_path"), .string("destination_path"),
                ]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            ),
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source_path": .object([
                        "type": .string("string"),
                        "description": .string("Vault-relative source path that was moved"),
                    ]),
                    "destination_path": .object([
                        "type": .string("string"),
                        "description": .string("Vault-relative destination path now containing the moved content"),
                    ])
                ]),
                "required": .array([
                    .string("source_path"),
                    .string("destination_path")
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private static func pathSchema(_ description: String) -> Value {
        .object([
            "type": .string("string"),
            "minLength": .int(1),
            "maxLength": .int(PathMoveRequestLimits.maximumPathBytes),
            "description": .string(
                description + "; the backend limit is measured in UTF-8 bytes"
            )
        ])
    }
}
