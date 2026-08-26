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
    ///   - startupRecovery: Writable-startup snapshot recovery.
    ///   - transport: MCP transport, injectable for lifecycle tests.
    /// - Throws: Transport or handler-registration errors. Recovery failures stay attached
    ///   to the mutation gate so reads and discovery remain available.
    static func start(
        config: ServerConfig,
        files: any FileCRUDService,
        directories: any DirectoryMoveService,
        search: any VaultSearchService,
        capabilities: FileCapabilities,
        startupRecovery: @escaping @Sendable () async throws -> Void = {},
        transport: any Transport = StdioTransport()
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
        let startupRecoveryGate = MCPStartupRecoveryGate()
        let server = Server(
            name: "SecondBrainMCP",
            version: "2.1.0",
            instructions: """
            This is a personal knowledge vault with format-aware file access. \
            Use search_vault to discover notes, then use the file CRUD tools with an explicit \
            concrete format. Use move_directory for a complete notes subtree; it does not take a format. \
            The CRUD tool schemas describe each format's accepted inputs and update modes. Every \
            file mutation that changes vault bytes is \
            automatically committed to git before the tool returns. If a mutation response is lost, \
            read the current vault state before deciding whether another mutation is needed. Before \
            update_file or delete_file, read the note and return its structured revision \
            as expected_revision. Use move_directory to relocate an entire notes subtree \
            in one call; do not recreate or move its files individually. A revision conflict requires reading and reconsidering \
            the note, never blindly retrying. The references/ area is read-only. Paths are \
            always relative to the vault root (for example, "notes/projects/app.md").
            """ + (customInstructions.map { "\n\n" + $0 } ?? ""),
            capabilities: .init(
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
            if params.name == DirectoryMoveToolDefinition.name
                || FileToolName(rawValue: params.name)?.operation.isMutation == true {
                try await startupRecoveryGate.wait()
            }
            if params.name == SearchToolDefinition.name {
                return try await searchTool.call(params)
            }
            if params.name == DirectoryMoveToolDefinition.name {
                return try await directoryTool.call(params)
            }
            return try await fileTools.call(params)
        }

        try await server.start(transport: transport)
        log("MCP server started, accepting connections")

        let startupRecoveryTask = await startupRecoveryGate.install {
            do {
                try await startupRecovery()
                log("startup recovery completed")
            } catch {
                log("startup recovery failed; mutations remain unavailable: \(error)")
                throw error
            }
        }
        await server.waitUntilCompleted()
        log("MCP transport completed; server shutting down")
        _ = await startupRecoveryTask.result
    }
}

/// Lets discovery and reads use a connected transport while mutations await recovery.
private actor MCPStartupRecoveryGate {
    private var task: Task<Void, Error>?
    private var taskWaiters: [CheckedContinuation<Task<Void, Error>, Never>] = []

    func install(
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Error> {
        precondition(task == nil, "Startup recovery may only be installed once")
        let installed = Task { try await operation() }
        task = installed
        taskWaiters.forEach { $0.resume(returning: installed) }
        taskWaiters.removeAll()
        return installed
    }

    func wait() async throws {
        let installed: Task<Void, Error>
        if let task {
            installed = task
        } else {
            installed = await withCheckedContinuation { continuation in
                taskWaiters.append(continuation)
            }
        }
        try await installed.value
    }
}
