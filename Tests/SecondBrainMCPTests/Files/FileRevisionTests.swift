import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Generic files — revision and mutation identities` {
    @Test
    func `Revision tokens require canonical lowercase SHA-256 text`() {
        let digest = String(repeating: "a", count: 64)

        #expect(FileRevision(rawValue: "sha256:\(digest)")?.rawValue == "sha256:\(digest)")
        #expect(FileRevision(rawValue: digest) == nil)
        #expect(FileRevision(rawValue: "sha256:\(digest.uppercased())") == nil)
        #expect(FileRevision(rawValue: "sha256:\(String(repeating: "a", count: 63))") == nil)
        #expect(FileRevision(rawValue: "sha256:\(String(repeating: "g", count: 64))") == nil)
    }

    @Test
    func `Snapshots derive revisions from exact stored bytes`() {
        let first = FileSnapshot(data: Data("hello".utf8), modifiedDate: nil)
        let sameBytes = FileSnapshot(data: Data("hello".utf8), modifiedDate: .now)
        let changed = FileSnapshot(data: Data("hello\n".utf8), modifiedDate: nil)

        #expect(
            first.revision.rawValue
                == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e"
                    + "1b161e5c1fa7425e73043362938b9824"
        )
        #expect(first.revision == sameBytes.revision)
        #expect(first.revision != changed.revision)
    }

    @Test
    func `Mutation IDs accept UUIDs and normalize their wire representation`() throws {
        let uppercase = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
        let identifier = try #require(MutationID(rawValue: uppercase))

        #expect(identifier.rawValue == uppercase.lowercased())
        #expect(MutationID(rawValue: "not-a-uuid") == nil)

        let encoded = try JSONEncoder().encode(identifier)
        let decoded = try JSONDecoder().decode(MutationID.self, from: encoded)
        #expect(decoded == identifier)
    }

    @Test
    func `Request fingerprints are stable only for the exact retry`() throws {
        let identifier = try #require(
            MutationID(rawValue: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        )
        let request = CreateFileRequest(
            mutationID: identifier,
            format: .markdown,
            path: "notes/example.md",
            content: "hello",
            source: nil,
            tags: ["test"],
            transform: nil
        )

        let first = try MutationRequestFingerprint.make(
            operation: .create,
            request: request
        )
        let identical = try MutationRequestFingerprint.make(
            operation: .create,
            request: request
        )
        let changed = try MutationRequestFingerprint.make(
            operation: .create,
            request: CreateFileRequest(
                mutationID: identifier,
                format: .markdown,
                path: "notes/example.md",
                content: "changed",
                source: nil,
                tags: ["test"],
                transform: nil
            )
        )

        #expect(first == identical)
        #expect(first != changed)
    }
}
