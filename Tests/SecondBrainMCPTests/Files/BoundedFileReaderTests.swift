import Darwin
import Foundation
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
