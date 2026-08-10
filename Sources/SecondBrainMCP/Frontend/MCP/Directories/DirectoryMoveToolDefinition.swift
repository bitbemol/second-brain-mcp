import MCP

/// Public contract for one efficient recursive notes-directory rename.
enum DirectoryMoveToolDefinition {
    static let name = MoveDirectoryRequest.operationIdentifier

    /// Builds the mutation tool unless the server is read-only.
    static func build(readOnly: Bool) -> Tool? {
        guard !readOnly else { return nil }
        return Tool(
            name: name,
            description: "Atomically move or rename one complete directory subtree under notes/ in a single operation. This structural operation does not take a file format: nested files and directories are preserved without reading or rewriting content. The source and destination must differ after case and Unicode normalization, and destination_path must not exist. Hidden and package subtrees are rejected. Empty directories move on disk but cannot be represented in Git. The completed files are discoverable by search_vault at their destination paths.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source_path": pathSchema(
                        "Existing directory under notes/, for example notes/in-progress/ticket-123"
                    ),
                    "destination_path": pathSchema(
                        "Exact unused destination under notes/, for example notes/completed/ticket-123"
                    )
                ]),
                "required": .array([
                    .string("source_path"),
                    .string("destination_path")
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
                    "source_path": .object(["type": .string("string")]),
                    "destination_path": .object(["type": .string("string")])
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
            "maxLength": .int(DirectoryMoveRequestLimits.maximumPathBytes),
            "description": .string(description + "; the backend limit is measured in UTF-8 bytes")
        ])
    }
}
