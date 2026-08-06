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
                description: "Create a supported concrete file under notes/. The declared format, destination extension, and actual content must agree. Text and structured formats require inline content. PNG imports and cleans an external image source. GIF creation accepts an external video source with transform=video_to_gif. Rejects existing destinations and git-commits the write.",
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
                            "description": .string("External regular-file path; supported only for PNG image import and GIF video conversion")
                        ]),
                        .tags: .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
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
                )
            )
        case .read:
            Tool(
                name: tool.rawValue,
                description: "Read a supported concrete file with format-specific behavior. Images may be resized or decomposed into timed GIF frames; PDFs return text plus rendered pages; HAR returns a summary unless raw=true; patches return a summary plus diff; logs default to the last 500 lines.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .read),
                    formatDescription: "Concrete file format; must match the path extension and actual content",
                    pathDescription: "Vault-relative path under notes/ or references/",
                    additionalProperties: [
                        .raw: .object(["type": .string("boolean"), "description": .string("Include complete raw HAR JSON (default false)")]),
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
                        .bookPage: .object(["type": .string("string"), "description": .string("For PDFs, printed page label")]),
                        .pageRange: .object(["type": .string("string"), "description": .string("For PDFs, range such as 10-20")]),
                        .query: .object(["type": .string("string"), "description": .string("For PDFs, find and render matching pages")]),
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
                )
            )
        case .update:
            Tool(
                name: tool.rawValue,
                description: "Update a supported file under notes/. Markdown supports replace, append, and exact text replacements. Canvas supports replace. Log supports append only. The update is rejected if an external editor changes the file while preparation is in progress. Git auto-commits.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .update),
                    formatDescription: "Concrete file format",
                    pathDescription: "Existing file under notes/",
                    additionalProperties: [
                        .mode: .object([
                            "type": .string("string"),
                            "enum": .array([.string("replace"), .string("append"), .string("patch")]),
                            "description": .string("Format-specific update mode (default replace)")
                        ]),
                        .content: .object(["type": .string("string"), "description": .string("Required for replace or append")]),
                        .replacements: .object([
                            "type": .string("array"),
                            "description": .string("Markdown patch mode: up to 20 exact, unique replacements"),
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
                    ]
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                )
            )
        case .delete:
            Tool(
                name: tool.rawValue,
                description: "Soft-delete a supported file under notes/ by moving it to .trash/. The declared format and extension must agree. References are structurally read-only. Git auto-commits the deletion.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .delete),
                    formatDescription: "Concrete file format",
                    pathDescription: "Existing file under notes/"
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                )
            )
        }
    }

    /// Builds the common format/path contract plus operation-specific fields.
    private static func inputSchema(
        formats: [FileFormat],
        formatDescription: String,
        pathDescription: String,
        additionalProperties: [FileToolArgument: Value] = [:]
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
            "required": requiredArguments([.format, .path])
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
