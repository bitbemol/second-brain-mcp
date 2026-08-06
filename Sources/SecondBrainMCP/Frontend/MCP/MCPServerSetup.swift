import Foundation
import MCP

/// Configures and runs the compact MCP transport over injected shared ports.
struct MCPServerSetup {
    /// Registers MCP handlers and serves over standard input/output.
    ///
    /// - Parameters:
    ///   - config: Validated runtime configuration.
    ///   - files: Shared file CRUD service boundary.
    ///   - capabilities: Immutable format capability manifest.
    ///   - rejections: Boundary-level rejection reporter.
    /// - Throws: Transport or handler-registration errors.
    static func start(
        config: ServerConfig,
        files: any FileCRUDService,
        capabilities: FileCapabilities,
        rejections: any FileRequestRejectionReporting
    ) async throws {
        let fileTools = FileToolController(
            readOnly: config.readOnly,
            rejections: rejections,
            files: files
        )
        let customInstructions = CustomInstructionsLoader.load(
            vaultPath: config.vaultPath
        )
        let server = Server(
            name: "SecondBrainMCP",
            version: "2.0.0",
            instructions: """
            This is a personal knowledge vault with format-aware file access. \
            Use create_file, read_file, update_file, and delete_file with an explicit \
            concrete format. Read secondbrain://file-capabilities before operating when \
            format support is uncertain. Every file mutation that changes vault bytes is \
            automatically committed to git. Every mutation requires a fresh caller-generated mutation_id UUID; \
            reuse it only when retrying that exact request after a lost response. Before \
            update_file or delete_file, read the note and return its structured revision \
            as expected_revision. A revision conflict requires reading and reconsidering \
            the note, never blindly retrying. The references/ area is read-only. Paths are \
            always relative to the vault root (for example, "notes/projects/app.md").
            """ + (customInstructions.map { "\n\n" + $0 } ?? ""),
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: FileToolDefinitions.build(
                capabilities: capabilities,
                readOnly: config.readOnly
            ))
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await fileTools.call(params)
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
