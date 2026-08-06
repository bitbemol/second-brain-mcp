import Foundation
import MCP

/// Exposes the shared file-capability manifest as a single MCP resource.
enum FileCapabilitiesResource {
    /// JSON representation of one concrete format's effective capabilities.
    private struct FormatManifest: Encodable {
        /// Concrete stored format exposed by the generic API.
        let format: FileFormat
        /// Accepted lowercase filename extensions.
        let extensions: [String]
        /// Effective operation support keyed by CRUD wire name.
        let operations: [String: OperationManifest]
    }

    /// JSON representation of the vault areas allowed for one operation.
    private struct OperationManifest: Encodable {
        /// Stable, sorted structural vault areas.
        let areas: [VaultArea]
    }

    /// Builds the complete v2 MCP resource surface.
    ///
    /// - Returns: Only the discoverable file-capabilities resource.
    static func list() -> [Resource] {
        [
            Resource(
                name: "File Capabilities",
                uri: "secondbrain://file-capabilities",
                description: "Concrete file formats and their effective CRUD operations, extensions, and vault areas",
                mimeType: "application/json"
            )
        ]
    }

    /// Serializes effective file support for `secondbrain://file-capabilities`.
    ///
    /// - Parameters:
    ///   - capabilities: Effective format, operation, and area support.
    ///   - readOnly: Whether mutation capabilities must be omitted.
    /// - Returns: A JSON MCP resource response with formats, extensions,
    ///   operations, and allowed vault areas.
    /// - Throws: An encoding error if the typed capability manifest cannot be
    ///   serialized.
    static func read(
        capabilities: FileCapabilities,
        readOnly: Bool
    ) throws -> ReadResource.Result {
        let entries = capabilities.formats.map { capability in
            var operations: [String: OperationManifest] = [:]

            for operation in FileCRUDOperation.allCases {
                guard !readOnly || !operation.isMutation,
                      let areas = capability.operations[operation] else {
                    continue
                }
                operations[operation.rawValue] = OperationManifest(
                    areas: areas.sorted { $0.rawValue < $1.rawValue }
                )
            }

            return FormatManifest(
                format: capability.format,
                extensions: capability.format.extensions.sorted(),
                operations: operations
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        let json = String(decoding: data, as: UTF8.self)
        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://file-capabilities", mimeType: "application/json")
        ])
    }
}
