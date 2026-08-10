import Foundation
import MCP

/// Configures and runs the compact MCP transport over injected shared ports.
struct MCPServerSetup {
    /// Registers MCP handlers and serves over standard input/output.
    ///
    /// - Parameters:
    ///   - config: Validated runtime configuration.
    ///   - files: Shared file CRUD service boundary.
    ///   - directories: Atomic recursive directory-move boundary.
    ///   - search: Shared read-only vault search boundary.
    ///   - capabilities: Immutable format capability manifest.
    /// - Throws: Transport or handler-registration errors.
    static func start(
        config: ServerConfig,
        files: any FileCRUDService,
        directories: any DirectoryMoveService,
        search: any VaultSearchService,
        capabilities: FileCapabilities
    ) async throws {
        let fileTools = FileToolController(
            readOnly: config.readOnly,
            files: files
        )
        let searchTool = SearchToolController(search: search)
        let directoryTool = DirectoryMoveToolController(
            readOnly: config.readOnly,
            directories: directories
        )
        let customInstructions = CustomInstructionsLoader.load(
            vaultPath: config.vaultPath
        )
        let server = Server(
            name: "SecondBrainMCP",
            version: "2.1.0",
            instructions: """
            This is a personal knowledge vault with format-aware file access. \
            Use search_vault to discover notes, then use the file CRUD tools with an explicit \
            concrete format. Use move_directory for a complete notes subtree; it does not take a format. \
            Read secondbrain://file-capabilities before file CRUD when \
            format support is uncertain. Every file mutation that changes vault bytes is \
            automatically committed to git before the tool returns. If a mutation response is lost, \
            read the current vault state before deciding whether another mutation is needed. Before \
            update_file or delete_file, read the note and return its structured revision \
            as expected_revision. Use move_directory to relocate an entire notes subtree \
            in one call; do not recreate or move its files individually. A revision conflict requires reading and reconsidering \
            the note, never blindly retrying. The references/ area is read-only. Paths are \
            always relative to the vault root (for example, "notes/projects/app.md").
            """ + (customInstructions.map { "\n\n" + $0 } ?? ""),
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            let fileDefinitions = FileToolDefinitions.build(
                capabilities: capabilities,
                readOnly: config.readOnly
            )
            var tools = fileDefinitions
            if let directoryDefinition = DirectoryMoveToolDefinition.build(
                readOnly: config.readOnly
            ) {
                tools.append(directoryDefinition)
            }
            tools.append(SearchToolDefinition.build())
            return ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            if params.name == SearchToolDefinition.name {
                return try await searchTool.call(params)
            }
            if params.name == DirectoryMoveToolDefinition.name {
                return try await directoryTool.call(params)
            }
            return try await fileTools.call(params)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: FileCapabilitiesResource.list())
        }

        await server.withMethodHandler(ReadResource.self) { params in
            guard params.uri == "secondbrain://file-capabilities" else {
                throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
            }
            return try FileCapabilitiesResource.read(
                capabilities: capabilities,
                readOnly: config.readOnly
            )
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        log("MCP server started, accepting connections")

        await server.waitUntilCompleted()
    }
}
