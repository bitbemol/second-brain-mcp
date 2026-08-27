import Foundation
import Testing
@testable import second_brain_mcp

@Suite(.serialized)
struct `Public tool performance baselines` {
    @Test
    func `records end to end latency for every public tool family`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicToolPerformanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references"),
            withIntermediateDirectories: true
        )
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: dataDirectory.rootURL)
            try? FileManager.default.removeItem(at: root)
        }

        let runtime = try await VaultRuntime.bootstrap(vaultPath: root.path)
        try await runtime.recoverPendingChanges()
        let body = String(repeating: "a", count: 256 * 1024) + "\nneedle"
        let replacement = String(repeating: "b", count: 256 * 1024) + "\nneedle"

        let (created, createTime) = try await measure {
            try await runtime.files.create(CreateFileRequest(
                format: .markdown,
                path: "notes/performance.md",
                content: body,
                source: nil,
                tags: [],
                transform: nil
            ))
        }
        let createdRevision = try #require(created.metadata?.revision)

        let (_, readTime) = try await measure {
            try await runtime.files.read(ReadFileRequest(
                format: .markdown,
                path: "notes/performance.md",
                options: ReadFileOptions()
            ))
        }

        let (updated, updateTime) = try await measure {
            try await runtime.files.update(UpdateFileRequest(
                expectedRevision: createdRevision,
                format: .markdown,
                path: "notes/performance.md",
                content: replacement,
                mode: .replace,
                replacements: []
            ))
        }
        var currentRevision = try #require(updated.metadata?.revision)

        let (_, searchTime) = try await measure {
            try await runtime.search.search(VaultSearchRequest(
                location: .notes,
                query: "needle",
                tags: [],
                createdFrom: nil,
                createdThrough: nil,
                limit: 20,
                cursor: nil
            ))
        }

        let thirdVersion = String(repeating: "c", count: 256 * 1024) + "\nneedle"
        try Data(thirdVersion.utf8).write(
            to: root.appendingPathComponent("notes/performance.md"),
            options: .atomic
        )
        let repository = try GitRepository(repositoryURL: root)
        let (_, gitSnapshotTime) = try await measure {
            try await repository.recordSnapshot()
        }
        let externallyUpdated = try await runtime.files.read(ReadFileRequest(
            format: .markdown,
            path: "notes/performance.md",
            options: ReadFileOptions()
        ))
        currentRevision = try #require(externallyUpdated.metadata?.revision)

        let sourceDirectory = root.appendingPathComponent("notes/move-source")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try Data("move me".utf8).write(
            to: sourceDirectory.appendingPathComponent("item.md"),
            options: .atomic
        )
        let (_, moveTime) = try await measure {
            try await runtime.directories.move(MoveDirectoryRequest(
                sourcePath: "notes/move-source",
                destinationPath: "notes/move-destination"
            ))
        }

        let (_, deleteTime) = try await measure {
            try await runtime.files.delete(DeleteFileRequest(
                expectedRevision: currentRevision,
                format: .markdown,
                path: "notes/performance.md"
            ))
        }

        let values = [
            "create_ms=\(milliseconds(createTime))",
            "read_ms=\(milliseconds(readTime))",
            "update_ms=\(milliseconds(updateTime))",
            "search_ms=\(milliseconds(searchTime))",
            "git_snapshot_ms=\(milliseconds(gitSnapshotTime))",
            "move_ms=\(milliseconds(moveTime))",
            "delete_ms=\(milliseconds(deleteTime))",
        ]
        print("PUBLIC_TOOL_BASELINE " + values.joined(separator: " "))

        for duration in [
            createTime, readTime, updateTime, searchTime, moveTime, deleteTime,
        ] {
            #expect(duration < .seconds(5))
        }
    }

    private func measure<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> (Value, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await operation()
        return (value, start.duration(to: clock.now))
    }

    private func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.3f", value)
    }
}
