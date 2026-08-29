import Darwin
import Foundation
import Synchronization
import Testing
@testable import second_brain_mcp

@Suite
struct `Bounded file reader` {
    private func temporaryFile(containing data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BoundedFileReader-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test
    func `Returns files exactly at the byte limit`() throws {
        let expected = Data(repeating: 0xAB, count: 128)
        let url = try temporaryFile(containing: expected)

        let actual = try BoundedFileReader.read(
            from: url,
            maximumBytes: expected.count,
            path: "notes/exact.bin"
        )

        #expect(actual == expected)
    }

    @Test
    func readableFileBeneathTraverseOnlyAncestorRemainsReadable() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedFileReader-traverse-\(UUID().uuidString)", isDirectory: true)
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
        let expected = Data("synthetic readable bytes".utf8)
        try expected.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try #require(Darwin.chmod(parent.path, 0o111) == 0)
        try #require(Data(contentsOf: file) == expected)

        let snapshot = try BoundedFileReader.snapshot(
            fromCanonical: file.resolvingSymlinksInPath(),
            maximumBytes: expected.count,
            path: "notes/readable.md",
            rejectHiddenDescendantsOf: root
        )

        #expect(snapshot.data == expected)
        #expect(snapshot.metadata.byteCount == expected.count)
    }

    @Test
    func ancestorWithoutSearchPermissionRemainsDenied() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedFileReader-no-search-\(UUID().uuidString)", isDirectory: true)
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
        let expected = Data("synthetic inaccessible bytes".utf8)
        try expected.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let canonicalFile = file.resolvingSymlinksInPath()
        let canonicalRoot = root.resolvingSymlinksInPath()
        try #require(Darwin.chmod(parent.path, 0o400) == 0)
        let direct = Darwin.open(canonicalFile.path, O_RDONLY | O_CLOEXEC)
        let directError = errno
        if direct >= 0 { Darwin.close(direct) }
        try #require(direct == -1)
        try #require(directError == EACCES)
        let observedBytes = Mutex(0)

        #expect(throws: POSIXError(.EACCES)) {
            _ = try BoundedFileReader.snapshot(
                fromCanonical: canonicalFile,
                maximumBytes: expected.count,
                path: "notes/readable.md",
                rejectHiddenDescendantsOf: canonicalRoot,
                didReadBytes: { count in observedBytes.withLock { $0 += count } }
            )
        }
        #expect(observedBytes.withLock { $0 } == 0)
    }

    @Test
    func `Stops after the first byte beyond the limit`() throws {
        let url = try temporaryFile(containing: Data(repeating: 0xCD, count: 1_000))

        do {
            _ = try BoundedFileReader.read(
                from: url,
                maximumBytes: 100,
                path: "notes/growing.bin"
            )
            Issue.record("Expected a file resource-policy violation")
        } catch let error as FileResourcePolicy.Violation {
            #expect(error.path == "notes/growing.bin")
            #expect(error.bytes == 1_000)
            #expect(error.limit == 100)
        } catch {
            Issue.record("Expected FileResourcePolicy.Violation, got \(error)")
        }
    }

    @Test
    func `A final symbolic link cannot redirect the descriptor open`() throws {
        let target = try temporaryFile(containing: Data("outside marker".utf8))
        let link = target.deletingLastPathComponent()
            .appendingPathComponent("BoundedFileReader-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        #expect(throws: BoundedFileReader.ReadError.self) {
            _ = try BoundedFileReader.read(
                from: link,
                maximumBytes: 1_000,
                path: "notes/link.md"
            )
        }
    }

    @Test
    func `A symbolic-link parent cannot redirect the descriptor open`() throws {
        let outsideDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BoundedFileReader-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: false
        )
        let outsideFile = outsideDirectory.appendingPathComponent("marker.md")
        try Data("outside marker".utf8).write(to: outsideFile)
        let link = outsideDirectory.deletingLastPathComponent()
            .appendingPathComponent("BoundedFileReader-parent-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outsideDirectory
        )

        #expect(throws: BoundedFileReader.ReadError.self) {
            _ = try BoundedFileReader.read(
                from: link.appendingPathComponent("marker.md"),
                maximumBytes: 1_000,
                path: "notes/parent-link/marker.md"
            )
        }
    }

    @Test
    func `Search-mode descriptor walks reject hidden descendants`() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BoundedFileReader-hidden-\(UUID().uuidString)")
        let hiddenParent = root.appendingPathComponent("parent")
        let hiddenFile = root.appendingPathComponent("hidden.md")
        let nestedFile = hiddenParent.appendingPathComponent("nested.md")
        defer {
            _ = Darwin.chflags(hiddenFile.path, 0)
            _ = Darwin.chflags(hiddenParent.path, 0)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: hiddenParent,
            withIntermediateDirectories: true
        )
        try Data("hidden file".utf8).write(to: hiddenFile)
        try Data("hidden parent".utf8).write(to: nestedFile)

        #expect(Darwin.chflags(hiddenFile.path, UInt32(UF_HIDDEN)) == 0)
        #expect(throws: BoundedFileReader.ReadError.self) {
            _ = try BoundedFileReader.snapshot(
                fromCanonical: hiddenFile,
                maximumBytes: 1_000,
                path: "notes/hidden.md",
                rejectHiddenDescendantsOf: root
            )
        }
        _ = Darwin.chflags(hiddenFile.path, 0)

        #expect(Darwin.chflags(hiddenParent.path, UInt32(UF_HIDDEN)) == 0)
        #expect(throws: BoundedFileReader.ReadError.self) {
            _ = try BoundedFileReader.snapshot(
                fromCanonical: nestedFile,
                maximumBytes: 1_000,
                path: "notes/parent/nested.md",
                rejectHiddenDescendantsOf: root
            )
        }
    }

    @Test
    func `Cancellation between path components closes the owned descriptor`() throws {
        let url = try temporaryFile(containing: Data("safe".utf8))
        var checks = 0
        var closedDescriptors: [Int32] = []
        do {
            _ = try BoundedFileReader.snapshot(
                fromCanonical: url,
                maximumBytes: 1_000,
                path: "notes/canceled-mid-open.md",
                cancellationCheck: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                },
                descriptorDidClose: { closedDescriptors.append($0) }
            )
            Issue.record("Expected cancellation during the descriptor walk")
        } catch is CancellationError {
            // Expected after the root and first component have both been opened.
        }

        // The root descriptor is closed during ownership transfer, and the
        // currently owned component is closed by the throwing-path defer.
        #expect(closedDescriptors.count == 2)
        #expect(Set(closedDescriptors).count == 2)
    }

    @Test
    func `A canceled task stops before opening or allocating file bytes`() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BoundedFileReader.read(
                from: URL(fileURLWithPath: "/does-not-matter"),
                maximumBytes: 1_000,
                path: "notes/canceled.md"
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
