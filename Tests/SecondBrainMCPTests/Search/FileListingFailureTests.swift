import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct FileListingFailureTests {
    @Test
    func oversizedRegisteredFileRemainsDiscoverable() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes/large.md")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        let byteCount = FileFormat.markdown.maximumFileBytes + 1
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()

        let result = try await listing(root).list(ListFilesRequest(area: .notes))

        #expect(result.files.map(\.path) == ["notes/large.md"])
        #expect(result.files.first?.byteCount == byteCount)
        #expect(result.nextCursor == nil)
    }

    @Test
    func listingDoesNotRequireReadPermissionOnAncestorsOutsideVault() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileListingTraverseTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("vault", isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: notes, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            _ = Darwin.chmod(parent.path, 0o700)
            try? FileManager.default.removeItem(at: parent)
        }
        let file = notes.appendingPathComponent("readable.md")
        let expected = Data("synthetic readable note".utf8)
        try expected.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try #require(Darwin.chmod(parent.path, 0o111) == 0)
        // The fixture allows known-path access, but not listing its unrelated ancestor.
        try #require(Data(contentsOf: file) == expected)

        let result = try await listing(root).list(
            ListFilesRequest(area: .notes, recursive: false, limit: 1)
        )

        #expect(result.files.map(\.path) == ["notes/readable.md"])
        #expect(result.files.first?.byteCount == expected.count)
        #expect(result.nextCursor == nil)
    }

    @Test
    func unreadableRegularFileCannotBecomeCompleteEmptyListing() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes/blocked.md")
        try Data("not readable".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        await #expect(throws: (any Error).self) {
            _ = try await listing(root).list(ListFilesRequest(area: .notes))
        }
    }

    @Test
    func emptySymlinkedAreaIsRejectedBeforeEnumeration() async throws {
        let root = try vault(includeNotes: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("notes"), withDestinationURL: outside
        )

        await #expect(throws: (any Error).self) {
            _ = try await listing(root).list(ListFilesRequest(area: .notes))
        }
    }

    @Test
    func finderHiddenAreaCannotBecomeCompleteEmptyListing() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        try Data("visible bytes".utf8).write(to: notes.appendingPathComponent("a.md"))
        guard Darwin.chflags(notes.path, UInt32(UF_HIDDEN)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.chflags(notes.path, 0) }

        await #expect(throws: (any Error).self) {
            _ = try await listing(root).list(ListFilesRequest(area: .notes))
        }
    }

    @Test
    func existingNonDirectoryAreaIsRejected() async throws {
        let root = try vault(includeNotes: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("notes"))

        await #expect(throws: (any Error).self) {
            _ = try await listing(root).list(ListFilesRequest(area: .notes))
        }
    }

    @Test
    func existingNonDirectorySelectedScopeIsRejected() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("notes/a.md"))

        await #expect(throws: (any Error).self) {
            _ = try await listing(root).list(ListFilesRequest(area: .notes, directory: "a.md"))
        }
    }

    @Test
    func missingExplicitDirectoryIsRejected() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: (any Error).self) {
            _ = try await listing(root).list(ListFilesRequest(area: .notes, directory: "missing"))
        }
    }

    @Test
    func enumerationOfAFileNeverReportsSuccessfulEmptyTraversal() throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes/a.md")
        try Data("not a directory".utf8).write(to: file)
        var scannedEntries = 0

        #expect(throws: (any Error).self) {
            _ = try BoundedDirectoryChildren.urls(
                below: file, resourceKeys: [], maximumEntries: 10,
                scannedEntries: &scannedEntries, limitError: FileListingError.scanLimitExceeded
            )
        }
    }

    @Test
    func absentOptionalAreaStillReturnsEmptyListing() async throws {
        let root = try vault(includeNotes: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await listing(root).list(ListFilesRequest(area: .notes))

        #expect(result.files.isEmpty)
        #expect(result.nextCursor == nil)
    }

    private func vault(includeNotes: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileListingFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if includeNotes {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("notes"), withIntermediateDirectories: false
            )
        }
        return root
    }

    private func listing(_ root: URL) -> VaultFileListingService {
        VaultFileListingService(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
            ]),
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
        )
    }
}
