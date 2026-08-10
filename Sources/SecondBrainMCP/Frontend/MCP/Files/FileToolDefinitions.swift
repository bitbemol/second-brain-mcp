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
                description: "Create a supported concrete file under notes/. Creation is atomic and requires the destination to be absent. The format field describes whether each registered type accepts content or source and whether it requires a transform. The declared format, destination extension, and actual content must agree. Specialized handlers validate or transform input before the shared persistence, revision, and Git pipeline.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .create),
                    formatDescription: createContractDescription(capabilities),
                    pathDescription: "Destination under notes/ with an extension matching format",
                    additionalProperties: [
                        .content: .object([
                            "type": .string("string"),
                            "description": .string(
                                inputDescription(.content, capabilities: capabilities)
                            )
                        ]),
                        .source: .object([
                            "type": .string("string"),
                            "maxLength": .int(
                                FileMutationRequestLimits.maximumSourcePathBytes
                            ),
                            "description": .string(
                                inputDescription(.source, capabilities: capabilities)
                            )
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
                            "description": .string(
                                tagDescription(capabilities)
                            )
                        ]),
                        .transform: .object([
                            "type": .string("string"),
                            "enum": .array(
                                FileCreateTransform.allCases.map {
                                    .string($0.rawValue)
                                }
                            ),
                            "description": .string(
                                transformDescription(capabilities)
                            )
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
                description: "Read one supported atomic file element. Reads under notes/ return an exact-byte revision in structuredContent and a trailing JSON text block; return that opaque value as expected_revision before updating or deleting the note. References are read-only and do not return revisions. Stored text formats return their complete validated content; HAR JSON is sanitized before it is stored and returned. Logs use bounded line windows, images may be resized or decomposed into timed GIF frames, and PDFs return physical pages as text plus PNG images.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .read),
                    formatDescription: "Concrete file format; must match the path extension and actual content",
                    pathDescription: "Vault-relative path under notes/ or references/",
                    additionalProperties: [
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
                            "description": .string("For PDFs, one physical 1-indexed page")
                        ]),
                        .pages: .object([
                            "type": .string("array"),
                            "minItems": .int(1),
                            "maxItems": .int(FileReadRequestLimits.maximumPDFPagesPerRead),
                            "uniqueItems": .bool(true),
                            "items": .object([
                                "type": .string("integer"),
                                "minimum": .int(1),
                            ]),
                            "description": .string("For PDFs, ordered physical pages; mutually exclusive with page and page_range"),
                        ]),
                        .pageRange: .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "maxLength": .int(FileReadRequestLimits.maximumPDFPageRangeBytes),
                            "pattern": .string("^\\d+-\\d+$"),
                            "description": .string("For PDFs, an inclusive physical range such as 7-10; mutually exclusive with page and pages"),
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
                description: "Update a supported file under notes/. The mode field describes the modes registered for each format. expected_revision must be the opaque revision returned by the read on which this edit is based; a conflict requires reading and reconsidering the file before retrying. The shared edit engine validates the final format-specific content before the persistence, revision, and Git pipeline. No-op results return the unchanged revision without creating a commit.",
                inputSchema: inputSchema(
                    formats: capabilities.supportedFormats(for: .update),
                    formatDescription: "Concrete file format",
                    pathDescription: "Existing file under notes/",
                    additionalProperties: [
                        .expectedRevision: expectedRevisionSchema,
                        .mode: .object([
                            "type": .string("string"),
                            "enum": .array(
                                FileUpdateMode.allCases.map {
                                    .string($0.rawValue)
                                }
                            ),
                            "description": .string(updateModeDescription(capabilities))
                        ]),
                        .content: .object(["type": .string("string"), "description": .string("Required for replace or append")]),
                        .replacements: .object([
                            "type": .string("array"),
                            "description": .string(
                                patchDescription(capabilities)
                            ),
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
                    additionalRequired: [.expectedRevision, .mode]
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

    private static func inputDescription(
        _ input: FileCreateContract.Input,
        capabilities: FileCapabilities
    ) -> String {
        let formats = capabilities.formats.compactMap { capability -> String? in
            guard capability.createContract?.input.rawValue == input.rawValue else {
                return nil
            }
            return capability.format.rawValue
        }
        return "Required \(input.rawValue) input for: "
            + formats.joined(separator: ", ")
    }

    private static func tagDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let formats = capabilities.formats.compactMap { capability in
            capability.createContract?.acceptsTags == true
                ? capability.format.rawValue
                : nil
        }
        return "Optional tags accepted by: " + formats.joined(separator: ", ")
    }

    private static func transformDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let entries = capabilities.formats.compactMap { capability -> String? in
            guard let transform = capability.createContract?.transform else {
                return nil
            }
            return "\(capability.format.rawValue)=\(transform.rawValue)"
        }
        return "Required create transforms: " + entries.joined(separator: ", ")
    }

    private static func patchDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let formats = capabilities.formats.compactMap { capability in
            capability.updateModes.contains(.patch)
                ? capability.format.rawValue
                : nil
        }
        return "Up to 20 exact, unique replacements for patch-capable formats: "
            + formats.joined(separator: ", ")
    }

    /// Describes create input directly from the backend catalog projection.
    private static func createContractDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let entries = capabilities.formats.compactMap { capability -> String? in
            guard let contract = capability.createContract else { return nil }
            let transform = contract.transform.map { "+\($0.rawValue)" } ?? ""
            return "\(capability.format.rawValue)=\(contract.input.rawValue)\(transform)"
        }
        return "Concrete stored file format and required input: "
            + entries.joined(separator: ", ")
    }

    /// Describes supported update modes directly from catalog registrations.
    private static func updateModeDescription(
        _ capabilities: FileCapabilities
    ) -> String {
        let entries = capabilities.formats.compactMap { capability -> String? in
            guard !capability.updateModes.isEmpty else { return nil }
            let modes = capability.updateModes
                .map(\.rawValue)
                .sorted()
                .joined(separator: "|")
            return "\(capability.format.rawValue)=\(modes)"
        }
        return "Format-specific update modes: " + entries.joined(separator: ", ")
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
            "required": requiredArguments([.format, .path] + additionalRequired),
            "additionalProperties": .bool(false)
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
