import Foundation

// SecondBrainMCP — local format-aware knowledge-vault server
// stdout is reserved for JSON-RPC (StdioTransport). All output goes to stderr.

// Ignore SIGPIPE so broken-pipe writes return EPIPE instead of killing the process.
// Without this, when Claude Desktop closes the stdin/stdout pipes (on conversation end,
// sleep, etc.), the server gets silently terminated by the default SIGPIPE handler.
signal(SIGPIPE, SIG_IGN)

do {
    // 1. Parse CLI arguments into config
    let config = try ServerConfig.parse(arguments: CommandLine.arguments)

    log("vault: \(config.vaultPath)")
    log("read-only: \(config.readOnly)")

    // 2. Compose the backend once at the application boundary.
    let runtime = try await VaultRuntime.bootstrap(
        vaultPath: config.vaultPath,
        readOnly: config.readOnly
    )
    log("backend: vault ready")

    // 3. Inject shared ports and serve until the client disconnects.
    try await MCPServerSetup.start(
        config: config,
        files: runtime.files,
        directories: runtime.directories,
        search: runtime.search,
        capabilities: runtime.capabilities
    )

} catch {
    log("fatal: \(error)")
    exit(1)
}
