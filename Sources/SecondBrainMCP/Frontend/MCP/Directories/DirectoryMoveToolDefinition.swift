import MCP

/// Public contract for one efficient recursive notes-directory rename.
enum DirectoryMoveToolDefinition {
    static let name = MoveDirectoryRequest.operationIdentifier

    /// Builds the mutation tool unless the server is read-only.
    static func build(readOnly: Bool) -> Tool? {
        guard !readOnly else { return nil }
        return Tool(
            name: name,
            description: "Atomically move or rename one complete directory subtree under notes/ in a single operation. Every nested file and subdirectory is preserved without reading or rewriting its content. destination_path is the exact new directory path and must not already exist. The move is committed to Git once and is immediately visible to search_vault under the new path_prefix. mutation_id is a caller-generated UUID; reuse it only to retry this exact move after a timeout.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mutation_id": .object([
                        "type": .string("string"),
                        "format": .string("uuid"),
                        "description": .string("Caller-generated UUID used only for exact retry of this move")
                    ]),
                    "source_path": pathSchema(
                        "Existing directory under notes/, for example notes/in-progress/ticket-123"
                    ),
                    "destination_path": pathSchema(
                        "Exact unused destination under notes/, for example notes/completed/ticket-123"
                    )
                ]),
                "required": .array([
                    .string("mutation_id"),
                    .string("source_path"),
                    .string("destination_path")
                ]),
                "additionalProperties": .bool(false)
            ]),
            annotations: .init(
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            ),
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source_path": .object(["type": .string("string")]),
                    "destination_path": .object(["type": .string("string")]),
                    "path": .object(["type": .string("string")]),
                    "area": .object([
                        "type": .string("string"),
                        "enum": .array([.string("notes")])
                    ]),
                    "mutation_id": .object(["type": .string("string")]),
                    "replayed": .object(["type": .string("boolean")])
                ]),
                "required": .array([
                    .string("source_path"),
                    .string("destination_path"),
                    .string("path"),
                    .string("area"),
                    .string("mutation_id"),
                    .string("replayed")
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
