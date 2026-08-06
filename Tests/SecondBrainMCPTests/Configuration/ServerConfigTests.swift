import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Server configuration")
struct ServerConfigTests {
    @Test("Vault and read-only arguments produce frontend configuration")
    func validArguments() throws {
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

    @Test("Legacy log-level arguments remain harmless")
    func legacyLogLevel() throws {
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

    @Test("Missing vault argument is rejected")
    func missingVault() {
        #expect(throws: ServerConfig.ConfigError.self) {
            try ServerConfig.parse(arguments: ["second-brain-mcp"])
        }
    }

    @Test("Empty vault values cannot select the process working directory")
    func rejectsEmptyVaultValue() {
        #expect(throws: ServerConfig.ConfigError.self) {
            try ServerConfig.parse(arguments: ["server", "--vault", ""])
        }
        #expect(throws: ServerConfig.ConfigError.self) {
            try ServerConfig.parse(arguments: ["server", "--vault", "   "])
        }
    }

    @Test("Regular file cannot be used as a vault")
    func vaultMustBeDirectory() throws {
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

    @Test("Vault aliases resolve to one canonical process identity")
    func canonicalizesVaultAlias() throws {
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
