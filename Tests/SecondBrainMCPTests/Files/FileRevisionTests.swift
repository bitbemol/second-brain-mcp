import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Generic files — exact-byte revisions` {
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
    func `Snapshot hashing is deferred and memoized until a revision is requested`() {
        let probe = RevisionProviderProbe()
        let expected = FileRevision(
            validatedSHA256Hex: String(repeating: "a", count: 64)
        )
        let snapshot = FileSnapshot(
            data: Data(repeating: 0xAA, count: 1_024),
            modifiedDate: nil,
            revisionProvider: { _ in
                probe.record()
                return expected
            }
        )

        #expect(probe.count == 0)
        #expect(snapshot.revision == expected)
        #expect(snapshot.revision == expected)
        #expect(probe.count == 1)
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
}

private final class RevisionProviderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}
