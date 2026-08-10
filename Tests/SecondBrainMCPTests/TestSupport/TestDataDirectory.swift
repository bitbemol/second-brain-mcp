import Foundation
@testable import second_brain_mcp

/// Creates isolated process data for tests without writing to Application Support.
func makeTestDataDirectory(vaultPath: String) throws -> VaultDataDirectory {
    let supportRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SecondBrainMCP-TestSupport-\(UUID().uuidString)")
    return try VaultDataDirectory.prepare(
        vaultPath: vaultPath,
        supportRoot: supportRoot
    )
}
