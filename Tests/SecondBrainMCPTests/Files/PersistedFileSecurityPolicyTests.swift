import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Persisted Git-candidate security policy")
struct PersistedFileSecurityPolicyTests {
    @Test("Structured HAR credentials are rejected")
    func rejectsCredentialBearingHAR() {
        let archive = #"{"log":{"entries":[{"request":{"headers":[{"name":"Authorization","value":"short-secret"}]}}]}}"#

        #expect(throws: PersistedFileSecurityPolicy.Violation.self) {
            try PersistedFileSecurityPolicy.validateGitCandidate(
                Data(archive.utf8),
                format: .har,
                path: "notes/captured.har"
            )
        }
    }

    @Test("Invalid UTF-8 is rejected for an obvious unknown text path")
    func rejectsInvalidUnknownTextEncoding() {
        #expect(throws: TextFileSupport.TextError.self) {
            try PersistedFileSecurityPolicy.validateGitCandidate(
                Data([0xff]),
                format: nil,
                path: "notes/settings.yaml"
            )
        }
    }

    @Test("Valid UTF-8 is scanned even when its extension names a binary format")
    func scansTextDisguisedAsKnownBinary() {
        let data = Data("api_key=abcdefghijklmnop1234567890".utf8)

        #expect(throws: SensitiveContentPolicy.Violation.self) {
            try PersistedFileSecurityPolicy.validateGitCandidate(
                data,
                format: .png,
                path: "notes/disguised.png"
            )
        }
    }

    @Test("Opaque unknown binary bytes retain the binary exemption")
    func permitsOpaqueUnknownBinary() throws {
        try PersistedFileSecurityPolicy.validateGitCandidate(
            Data([0xff]),
            format: nil,
            path: "notes/opaque.bin"
        )
    }
}
