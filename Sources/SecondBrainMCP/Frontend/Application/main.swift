import Dispatch
import Foundation

// SecondBrainMCP — local format-aware knowledge-vault server
// stdout is reserved for JSON-RPC (StdioTransport). All output goes to stderr.

// Ignore SIGPIPE so broken-pipe writes return EPIPE instead of killing the process.
// Without this, when Claude Desktop closes the stdin/stdout pipes (on conversation end,
// sleep, etc.), the server gets silently terminated by the default SIGPIPE handler.
signal(SIGPIPE, SIG_IGN)

do {
    // Client shutdown commonly sends SIGTERM rather than closing stdin. Route
    // termination through the same owned-task drain as EOF so Git teardown can
    // run while the parent is alive. No asynchronous work runs in a signal handler.
    let transport = StdioMessageTransport()
    let terminationSources = [SIGTERM, SIGINT, SIGHUP].map { terminationSignal in
        signal(terminationSignal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: terminationSignal, queue: .global(qos: .utility)
        )
        source.setEventHandler { @Sendable in
            Task { await transport.disconnect() }
        }
        source.resume()
        return source
    }
    defer { terminationSources.forEach { $0.cancel() } }

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
        paths: runtime.paths,
        search: runtime.search,
        links: runtime.links,
        listing: runtime.listing,
        capabilities: runtime.capabilities,
        startupRecovery: { try await runtime.recoverPendingChanges() },
        transport: transport
    )

} catch {
    log("fatal: \(error)")
    exit(1)
}
