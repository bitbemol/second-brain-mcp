import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Server configuration` {
    @Test
    func `Vault and read-only arguments produce frontend configuration`() throws {
        let vaultPath = try makeVault()

        let config = try ServerConfig.parse(arguments: [
            "second-brain-mcp",
            "--vault",
            vaultPath,
            "--read-only",
        ])

        #expect(config.vaultPath == canonical(vaultPath))
        #expect(config.readOnly)
    }

    @Test
    func `Legacy log-level arguments remain harmless`() throws {
        let vaultPath = try makeVault()

        let config = try ServerConfig.parse(arguments: [
            "second-brain-mcp",
            "--log-level",
            "debug",
            "--vault",
            vaultPath,
        ])

        #expect(config.vaultPath == canonical(vaultPath))
        #expect(!config.readOnly)
    }

    @Test
    func `Missing vault argument is rejected`() {
        #expect(throws: ServerConfig.ConfigError.self) {
            try ServerConfig.parse(arguments: ["second-brain-mcp"])
        }
    }

    @Test
    func `Empty vault values cannot select the process working directory`() {
        #expect(throws: ServerConfig.ConfigError.self) {
            try ServerConfig.parse(arguments: ["server", "--vault", ""])
        }
        #expect(throws: ServerConfig.ConfigError.self) {
            try ServerConfig.parse(arguments: ["server", "--vault", "   "])
        }
    }

    @Test
    func `Regular file cannot be used as a vault`() throws {
        let path = NSTemporaryDirectory() + "ServerConfigTests-\(UUID().uuidString).txt"
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: path))

        #expect(throws: ServerConfig.ConfigError.self) {
            try ServerConfig.parse(arguments: [
                "second-brain-mcp",
                "--vault",
                path,
            ])
        }
    }

    @Test
    func `Vault aliases resolve to one canonical process identity`() throws {
        let vaultPath = try makeVault()
        let alias = NSTemporaryDirectory()
            + "ServerConfigTests-alias-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(
            atPath: alias,
            withDestinationPath: vaultPath
        )

        let config = try ServerConfig.parse(arguments: [
            "second-brain-mcp", "--vault", alias,
        ])

        #expect(config.vaultPath == canonical(vaultPath))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
    }

    private func makeVault() throws -> String {
        let path = NSTemporaryDirectory() + "ServerConfigTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        return path
    }
}
