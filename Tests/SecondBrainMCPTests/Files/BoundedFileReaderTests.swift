import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Bounded file reader")
struct BoundedFileReaderTests {
    private func temporaryFile(containing data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BoundedFileReader-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test("Returns files exactly at the byte limit")
    func exactLimit() throws {
        let expected = Data(repeating: 0xAB, count: 128)
        let url = try temporaryFile(containing: expected)

        let actual = try BoundedFileReader.read(
            from: url,
            maximumBytes: expected.count,
            path: "notes/exact.bin"
        )

        #expect(actual == expected)
    }

    @Test("Stops after the first byte beyond the limit")
    func rejectsOverflowEarly() throws {
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

    @Test("A final symbolic link cannot redirect the descriptor open")
    func rejectsSymbolicLink() throws {
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

    @Test("A symbolic-link parent cannot redirect the descriptor open")
    func rejectsSymbolicLinkParent() throws {
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

    @Test("Cancellation between path components closes the owned descriptor")
    func midOpenCancellationClosesDescriptor() throws {
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

    @Test("A canceled task stops before opening or allocating file bytes")
    func cancellation() async {
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
