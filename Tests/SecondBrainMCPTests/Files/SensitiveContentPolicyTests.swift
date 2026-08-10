import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Sensitive content policy` {
    @Test
    func `High-confidence credential forms are rejected without disclosure`() throws {
        let credentials = [
            "Authorization: Bearer " + String(repeating: "a", count: 32),
            "Authorization: Basic " + String(repeating: "b", count: 28),
            "Set-Cookie: session=" + String(repeating: "c", count: 32),
            "access_token=" + String(repeating: "d", count: 32),
            "eyJheader123.payload123.signature123",
            "sk-proj-" + String(repeating: "e", count: 24),
            "ghp_" + String(repeating: "f", count: 24),
            "github_pat_" + String(repeating: "g", count: 24),
            "sk_live_" + String(repeating: "h", count: 24),
            "aws_secret_access_key=" + String(repeating: "i", count: 40),
            "AKIA" + String(repeating: "G", count: 16),
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----",
            "https://alice:supersecretpassword@example.com/private",
            "https://example.com/login?password=supersecretpassword",
            "https://example.com/login?pass%77ord=supersecretpassword",
            "https://example.com/login?access%5Ftoken=abcdefghijklmnop1234",
        ]

        for credential in credentials {
            let text = "safe first line\n\(credential)\nsafe last line"
            do {
                try SensitiveContentPolicy.validate(
                    Data(text.utf8),
                    format: .markdown,
                    path: "notes/security.md"
                )
                Issue.record("Expected credential rejection")
            } catch let violation as SensitiveContentPolicy.Violation {
                #expect(violation.path == "notes/security.md")
                #expect(violation.line == 2)
                #expect(!violation.detector.isEmpty)
                #expect(!violation.description.contains(credential))
            }
        }
    }

    @Test
    func `Explicit placeholders and ordinary prose remain writable`() throws {
        let safe = """
        Authorization: Bearer <YOUR_TOKEN>
        access_token=${ACCESS_TOKEN}
        api_key=example_api_key_value
        Cookie: session=[REDACTED]
        Explain that Authorization headers should never be committed.
        Bearer authentication is an HTTP authorization scheme.
        Bearer authentication-token is documented here.
        Bearer authorization-header semantics are documented here.
        """

        try SensitiveContentPolicy.validate(
            Data(safe.utf8),
            format: .markdown,
            path: "notes/documentation.md"
        )
    }

    @Test
    func `Uppercase symbolic credential identifiers remain writable`() throws {
        let safe = [
            "Bearer ACTUAL_LITELLM_API_KEY",
            "Authorization: Bearer LITELLM_ACCESS_TOKEN",
            "Authorization: SERVICE_CLIENT_SECRET",
            "api_key=TEST_PROVIDER_V2_API_KEY",
            "access_token=DOCUMENTED_ACCESS_TOKEN",
            "password=DATABASE_PASSWORD",
        ]

        for value in safe {
            try SensitiveContentPolicy.validate(
                Data(value.utf8),
                format: .markdown,
                path: "notes/setup.md"
            )
        }
    }

    @Test
    func `Symbolic exemption does not admit opaque or malformed credentials`() {
        let unsafe = [
            // Case must be exact: mixed-case values can be real credentials.
            "Bearer Actual_LITELLM_API_KEY",
            "Bearer ACTUAL_LiteLLM_API_KEY",
            // Uppercase alone does not make an opaque value a placeholder.
            "Bearer ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
            // Underscores alone are insufficient without a credential noun.
            "Bearer ABCDEFGHIJKL_MNOPQRSTUVWX_0123456789",
            // Empty, leading, and trailing components are not identifiers.
            "Bearer ACTUAL__LITELLM_API_KEY",
            "Bearer _ACTUAL_LITELLM_API_KEY",
            "Bearer ACTUAL_LITELLM_API_KEY_",
            // Non-identifier punctuation remains credential-shaped input.
            "Bearer ACTUAL.LITELLM.API.KEY.012345",
        ]

        for value in unsafe {
            #expect(throws: SensitiveContentPolicy.Violation.self) {
                try SensitiveContentPolicy.validate(
                    Data(value.utf8),
                    format: .markdown,
                    path: "notes/security.md"
                )
            }
        }
    }

    @Test
    func `Known provider credentials cannot use the symbolic exemption`() {
        let unsafe = [
            "Bearer sk-proj-" + String(repeating: "A", count: 24),
            "Bearer github_pat_" + String(repeating: "B", count: 24),
            "Bearer AKIA" + String(repeating: "7", count: 16),
        ]

        for value in unsafe {
            #expect(throws: SensitiveContentPolicy.Violation.self) {
                try SensitiveContentPolicy.validate(
                    Data(value.utf8),
                    format: .markdown,
                    path: "notes/security.md"
                )
            }
        }
    }

    @Test
    func `Placeholders must occupy the complete credential value`() {
        let unsafe = [
            "api_key=exampleRealProductionToken12345",
            "Cookie: first=example_token_value; session="
                + String(repeating: "r", count: 32),
        ]
        for value in unsafe {
            #expect(throws: SensitiveContentPolicy.Violation.self) {
                try SensitiveContentPolicy.validate(
                    Data(value.utf8),
                    format: .markdown,
                    path: "notes/security.md"
                )
            }
        }
    }

    @Test
    func `JSON Unicode escapes cannot hide keys or credential values`() {
        let secret = String(repeating: "s", count: 32)
        let escapedSecret = secret.unicodeScalars.map {
            String(format: "\\u%04X", $0.value)
        }.joined()
        let documents = [
            #"{"access\u005ftoken":""# + secret + #""}"#,
            #"{"access_token":""# + escapedSecret + #""}"#,
            #"{"embedded":"{\"access_token\":\""#
                + escapedSecret + #"\"}"}"#,
        ]

        for document in documents {
            #expect(throws: SensitiveContentPolicy.Violation.self) {
                try SensitiveContentPolicy.validate(
                    Data(document.utf8),
                    format: .json,
                    path: "notes/fixture.json"
                )
            }
        }
    }

    @Test
    func `Quoted JSON cookie members receive pair-wise scanning`() {
        let secret = String(repeating: "c", count: 32)
        let document = #"{"Cookie":"placeholder=example_token_value; session="#
            + secret + #"","safe":true}"#

        #expect(throws: SensitiveContentPolicy.Violation.self) {
            try SensitiveContentPolicy.validate(
                Data(document.utf8),
                format: .canvas,
                path: "notes/cookies.canvas"
            )
        }
    }

    @Test
    func `Invalid UTF-8 fails closed at the central text boundary`() {
        #expect(throws: TextFileSupport.TextError.self) {
            try SensitiveContentPolicy.validate(
                Data([0xff, 0xfe]),
                format: .log,
                path: "notes/invalid.log"
            )
        }
    }

    @Test
    func `All Git-tracked textual formats share the same rejection boundary`() {
        let credential = Data(
            ("Bearer " + String(repeating: "k", count: 32)).utf8
        )
        for format in [
            FileFormat.markdown, .canvas, .har, .patch, .log, .json, .csv,
        ] {
            #expect(throws: SensitiveContentPolicy.Violation.self) {
                try SensitiveContentPolicy.validate(
                    credential,
                    format: format,
                    path: "notes/file.\(format.rawValue)"
                )
            }
        }
    }

    @Test
    func `Line diagnostics treat CRLF and CR as logical delimiters`() throws {
        let credential = "Bearer " + String(repeating: "m", count: 32)
        for separator in ["\r\n", "\r", "\n"] {
            do {
                try SensitiveContentPolicy.validate(
                    Data(("safe\(separator)\(credential)").utf8),
                    format: .log,
                    path: "notes/app.log"
                )
                Issue.record("Expected credential rejection")
            } catch let violation as SensitiveContentPolicy.Violation {
                #expect(violation.line == 2)
            }
        }
    }

    @Test
    func `Binary formats are not interpreted as credential-bearing text`() throws {
        let apparentSecret = Data(
            ("Bearer " + String(repeating: "z", count: 32)).utf8
        )
        try SensitiveContentPolicy.validate(
            apparentSecret,
            format: .png,
            path: "notes/image.png"
        )
    }

    @Test
    func `Text size limits run before credential scanning`() {
        let prefix = "Bearer " + String(repeating: "z", count: 32)
        let oversized = prefix + String(
            repeating: " ",
            count: FileFormat.markdown.maximumFileBytes
        )
        #expect(throws: FileResourcePolicy.Violation.self) {
            try SensitiveContentPolicy.validate(
                Data(oversized.utf8),
                format: .markdown,
                path: "notes/oversized.md"
            )
        }
    }

    @Test
    func `Mutation text is bounded before fingerprinting and format parsing`() throws {
        let limit = FileFormat.markdown.maximumFileBytes
        try FileMutationResourcePreflight.validate(CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: "notes/near-limit.md",
            content: String(repeating: "a", count: limit),
            source: nil,
            tags: [],
            transform: nil
        ))

        let largeReplacement = String(repeating: "b", count: 8 * 1024 * 1024)
        try FileMutationResourcePreflight.validate(UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: FileSnapshot(
                data: Data(),
                modifiedDate: nil
            ).revision,
            format: .markdown,
            path: "notes/large-valid-patch.md",
            content: nil,
            mode: .patch,
            replacements: [TextReplacement(
                oldText: largeReplacement,
                newText: largeReplacement
            )]
        ))

        #expect(throws: FileResourcePolicy.Violation.self) {
            try FileMutationResourcePreflight.validate(UpdateFileRequest(
                mutationID: MutationID(),
                expectedRevision: FileSnapshot(
                    data: Data(),
                    modifiedDate: nil
                ).revision,
                format: .markdown,
                path: "notes/oversized-patch.md",
                content: nil,
                mode: .patch,
                replacements: [
                    TextReplacement(
                        oldText: largeReplacement,
                        newText: largeReplacement
                    ),
                    TextReplacement(
                        oldText: largeReplacement,
                        newText: largeReplacement
                    ),
                ]
            ))
        }

        #expect(throws: FileMutationResourcePreflight.Violation.self) {
            try FileMutationResourcePreflight.validate(CreateFileRequest(
                mutationID: MutationID(),
                format: .markdown,
                path: "notes/tags.md",
                content: "safe",
                source: nil,
                tags: Array(
                    repeating: "tag",
                    count: FileMutationRequestLimits.maximumTagCount + 1
                ),
                transform: nil
            ))
        }
        #expect(throws: FileMutationResourcePreflight.Violation.self) {
            try FileMutationResourcePreflight.validate(CreateFileRequest(
                mutationID: MutationID(),
                format: .png,
                path: "notes/image.png",
                content: nil,
                source: String(
                    repeating: "s",
                    count: FileMutationRequestLimits.maximumSourcePathBytes + 1
                ),
                tags: [],
                transform: nil
            ))
        }
    }
}
