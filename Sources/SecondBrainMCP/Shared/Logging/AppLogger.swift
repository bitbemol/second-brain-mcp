import Foundation

/// Process-level diagnostics shared by the application entry point and MCP
/// frontend. Stdout is reserved exclusively for JSON-RPC transport.
func log(_ message: String) {
    fputs("SecondBrainMCP: \(message)\n", stderr)
}
