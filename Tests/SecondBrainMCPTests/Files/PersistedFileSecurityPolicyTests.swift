import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Persisted Git-candidate security policy` {
    @Test
    func `Structured HAR credentials are rejected`() {
        let archive = #"{"log":{"entries":[{"request":{"headers":[{"name":"Authorization","value":"short-secret"}]}}]}}"#

        #expect(throws: PersistedFileSecurityPolicy.Violation.self) {
            try PersistedFileSecurityPolicy.validateGitCandidate(
                Data(archive.utf8),
                format: .har,
                path: "notes/captured.har"
            )
        }
    }

    @Test
    func `Invalid UTF-8 is rejected for an obvious unknown text path`() {
        #expect(throws: TextFileSupport.TextError.self) {
            try PersistedFileSecurityPolicy.validateGitCandidate(
                Data([0xff]),
                format: nil,
                path: "notes/settings.yaml"
            )
        }
    }

    @Test
    func `Valid UTF-8 is scanned even when its extension names a binary format`() {
        let data = Data("api_key=abcdefghijklmnop1234567890".utf8)

        #expect(throws: SensitiveContentPolicy.Violation.self) {
            try PersistedFileSecurityPolicy.validateGitCandidate(
                data,
                format: .png,
                path: "notes/disguised.png"
            )
        }
    }

    @Test
    func `Opaque unknown binary bytes retain the binary exemption`() throws {
        try PersistedFileSecurityPolicy.validateGitCandidate(
            Data([0xff]),
            format: nil,
            path: "notes/opaque.bin"
        )
    }
}
