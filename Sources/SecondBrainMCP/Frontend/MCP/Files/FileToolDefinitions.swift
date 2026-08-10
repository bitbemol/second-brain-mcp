import Foundation
import MCP

/// Builds the compact, capability-derived MCP file tool definitions.
enum FileToolDefinitions {
    /// Builds JSON-schema tool definitions from the shared capability manifest.
    ///
    /// The schema format enums are derived from `capabilities`; adding a format never
    /// requires duplicating its name in this frontend adapter.
    ///
    /// - Parameters:
    ///   - capabilities: Effective format, operation, and area support.
    ///   - readOnly: Whether mutating tools must be omitted.
    /// - Returns: The effective generic file tools.
    static func build(capabilities: FileCapabilities, readOnly: Bool) -> [Tool] {
        FileToolName.allCases.compactMap { tool in
            guard !readOnly || !tool.operation.isMutation else { return nil }
            return definition(for: tool, capabilities: capabilities)
        }
    }

    /// Builds the operation-specific schema for one registered tool name.
    private static func definition(
        for tool: FileToolName,
        capabilities: FileCapabilities
    ) -> Tool {
        switch tool {
        case .create:
            Tool(
                name: tool.rawValue,
                description: "Create a supported concrete file under notes/. Creation is atomic and requires the destination to be absent. The declared format, destination extension, and actual content must agree. Text and structured formats require inline content and reject high-confidence credentials before Git persistence; use explicit redaction placeholders in documentation. HAR imports redact known authorization, cookie, token, URL-userinfo, and JSON/form-body credential fields. PNG imports and cleans an external image source. GIF creation accepts an external video source with transform=video_to_gif. Successful results return the stored revision and are git-committed.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .create),
                    formatDescription: "Concrete stored file format",
                    pathDescription: "Destination under notes/ with an extension matching format",
                    additionalProperties: [
                        .content: .object([
                            "type": .string("string"),
                            "description": .string("Inline UTF-8 content; required for text and structured formats")
                        ]),
                        .source: .object([
                            "type": .string("string"),
                            "maxLength": .int(
                                FileMutationRequestLimits.maximumSourcePathBytes
                            ),
                            "description": .string("External regular-file path; supported only for PNG image import and GIF video conversion")
                        ]),
                        .tags: .object([
                            "type": .string("array"),
                            "maxItems": .int(
                                FileMutationRequestLimits.maximumTagCount
                            ),
                            "items": .object([
                                "type": .string("string"),
                                "maxLength": .int(
                                    FileMutationRequestLimits.maximumTagBytes
                                )
                            ]),
                            "description": .string("Markdown tags used when frontmatter is generated")
                        ]),
                        .transform: .object([
                            "type": .string("string"),
                            "enum": .array([.string("video_to_gif")]),
                            "description": .string("Required when creating a GIF from an external video")
                        ])
                    ]
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: true
                ),
                outputSchema: outputSchema(
                    required: [.path, .area, .revision]
                )
            )
        case .read:
            Tool(
                name: tool.rawValue,
                description: "Read a supported concrete file with format-specific behavior. Reads under notes/ return an exact-byte revision in structuredContent; return that opaque value as expected_revision before updating or deleting the note. References are read-only and do not return revisions. JSON and CSV return their complete validated source text. Images may be resized or decomposed into timed GIF frames; PDFs return text plus rendered pages; HAR returns a summary unless raw=true, and raw output is sanitized or rejected when unknown credential patterns remain; patches return a summary plus diff; logs default to the last 500 lines.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .read),
                    formatDescription: "Concrete file format; must match the path extension and actual content",
                    pathDescription: "Vault-relative path under notes/ or references/",
                    additionalProperties: [
                        .raw: .object(["type": .string("boolean"), "description": .string("Include complete sanitized HAR JSON; unknown credential patterns are rejected (default false)")]),
                        .tailLines: .object([
                            "type": .string("integer"), "minimum": .int(1), "maximum": .int(5_000),
                            "description": .string("For logs, return the last N lines")
                        ]),
                        .startLine: .object([
                            "type": .string("integer"), "minimum": .int(1),
                            "description": .string("For logs, first 1-indexed line to return")
                        ]),
                        .maxLines: .object([
                            "type": .string("integer"), "minimum": .int(1), "maximum": .int(5_000),
                            "description": .string("For logs with start_line, maximum lines")
                        ]),
                        .page: .object([
                            "type": .string("integer"), "minimum": .int(1),
                            "description": .string("For PDFs, physical 1-indexed page")
                        ]),
                        .bookPage: .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(FileReadRequestLimits.maximumPDFBookPageBytes),
                            "description": .string("For PDFs, printed page label; the backend limit is measured in UTF-8 bytes"),
                        ]),
                        .pageRange: .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(FileReadRequestLimits.maximumPDFPageRangeBytes),
                            "description": .string("For PDFs, range such as 10-20; the backend limit is measured in UTF-8 bytes"),
                        ]),
                        .maxPages: .object([
                            "type": .string("integer"), "minimum": .int(1), "maximum": .int(20),
                            "description": .string("For PDFs, maximum pages (default 5)")
                        ])
                    ]
                ),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                ),
                outputSchema: outputSchema(
                    required: [.path, .area]
                )
            )
        case .update:
            Tool(
                name: tool.rawValue,
                description: "Update a supported file under notes/. expected_revision must be the opaque revision returned by the read on which this edit is based; a conflict requires reading and reconsidering the file before retrying. Text updates reject high-confidence credentials before persistence. Markdown and CSV support replace, append, and exact text replacements. JSON supports replace and exact text replacements. Canvas supports replace. Log supports append only. Changed-byte results return the new stored revision and are git-committed; no-op results return the unchanged revision without creating a commit.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .update),
                    formatDescription: "Concrete file format",
                    pathDescription: "Existing file under notes/",
                    additionalProperties: [
                        .expectedRevision: expectedRevisionSchema,
                        .mode: .object([
                            "type": .string("string"),
                            "enum": .array([.string("replace"), .string("append"), .string("patch")]),
                            "description": .string("Format-specific update mode (default replace)")
                        ]),
                        .content: .object(["type": .string("string"), "description": .string("Required for replace or append")]),
                        .replacements: .object([
                            "type": .string("array"),
                            "description": .string("Patch mode for Markdown, JSON, and CSV: up to 20 exact, unique replacements"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": argumentObject([
                                    .oldText: .object([
                                        "type": .string("string"),
                                        "minLength": .int(1),
                                    ]),
                                    .newText: .object(["type": .string("string")])
                                ]),
                                "required": requiredArguments([.oldText, .newText])
                            ])
                        ])
                    ],
                    additionalRequired: [.expectedRevision]
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                ),
                outputSchema: outputSchema(
                    required: [.path, .area, .revision]
                )
            )
        case .delete:
            Tool(
                name: tool.rawValue,
                description: "Soft-delete a supported file under notes/ by moving it to .trash/. expected_revision must be the opaque revision returned by the read that authorized deletion; a conflict requires a fresh read. The declared format and extension must agree. References are structurally read-only. Git auto-commits the deletion.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .delete),
                    formatDescription: "Concrete file format",
                    pathDescription: "Existing file under notes/",
                    additionalProperties: [
                        .expectedRevision: expectedRevisionSchema,
                    ],
                    additionalRequired: [.expectedRevision]
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                ),
                outputSchema: outputSchema(
                    required: [.path, .area]
                )
            )
        }
    }

    /// Builds the common format/path contract plus operation-specific fields.
    private static func inputSchema(
        formats: [FileFormat],
        formatDescription: String,
        pathDescription: String,
        additionalProperties: [FileToolArgument: Value] = [:],
        additionalRequired: [FileToolArgument] = []
    ) -> Value {
        var properties = additionalProperties
        properties[.format] = .object([
            "type": .string("string"),
            "enum": .array(formats.map { .string($0.rawValue) }),
            "description": .string(formatDescription)
        ])
        properties[.path] = .object([
            "type": .string("string"),
            "description": .string(pathDescription)
        ])
        return .object([
            "type": .string("object"),
            "properties": argumentObject(properties),
            "required": requiredArguments([.format, .path] + additionalRequired)
        ])
    }

    /// Schema for exact-byte compare-and-swap revision preconditions.
    private static var expectedRevisionSchema: Value {
        .object([
            "type": .string("string"),
            "pattern": .string("^sha256:[0-9a-f]{64}$"),
            "description": .string(
                "Required opaque revision returned by read_file for this note. Never guess or substitute a revision from a conflict response."
            ),
        ])
    }

    /// Builds the structured metadata schema returned alongside content blocks.
    private static func outputSchema(required: [FileToolOutputField]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                FileToolOutputField.path.rawValue: .object(["type": .string("string")]),
                FileToolOutputField.area.rawValue: .object([
                    "type": .string("string"),
                    "enum": .array(VaultArea.allCases.map { .string($0.rawValue) }),
                ]),
                FileToolOutputField.revision.rawValue: .object([
                    "type": .string("string"),
                    "pattern": .string("^sha256:[0-9a-f]{64}$"),
                ]),
            ]),
            "required": .array(required.map { .string($0.rawValue) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// Converts typed argument properties to their MCP wire names.
    private static func argumentObject(
        _ properties: [FileToolArgument: Value]
    ) -> Value {
        .object(Dictionary(uniqueKeysWithValues: properties.map {
            ($0.key.rawValue, $0.value)
        }))
    }

    /// Builds a JSON Schema required list from typed argument names.
    private static func requiredArguments(
        _ arguments: [FileToolArgument]
    ) -> Value {
        .array(arguments.map { .string($0.rawValue) })
    }
}
