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
        let (_, metadataReadTime) = try await measure {
            try await runtime.files.read(ReadFileRequest(
                format: .markdown,
                path: "notes/performance.md",
                options: ReadFileOptions(view: .metadata)
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
        let repository = try GitRepository(
            vaultURL: root,
            dataDirectory: dataDirectory
        )
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
            try await runtime.paths.move(.directory(
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
            "metadata_read_ms=\(milliseconds(metadataReadTime))",
            "update_ms=\(milliseconds(updateTime))",
            "search_ms=\(milliseconds(searchTime))",
            "git_snapshot_ms=\(milliseconds(gitSnapshotTime))",
            "move_ms=\(milliseconds(moveTime))",
            "delete_ms=\(milliseconds(deleteTime))",
        ]
        print("PUBLIC_TOOL_BASELINE " + values.joined(separator: " "))

        for duration in [
            createTime, readTime, metadataReadTime, updateTime, searchTime,
            gitSnapshotTime, moveTime, deleteTime,
        ] {
            #expect(duration < .seconds(5))
        }
    }

    @Test
    func `exact snapshot of ten thousand notes stays below the interactive ceiling`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCorpusPerformanceTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("bounded note bytes\n".utf8)
        for index in 0..<10_000 {
            try payload.write(
                to: notes.appendingPathComponent(String(format: "%05d.md", index))
            )
        }
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root.path,
            supportRoot: support
        )
        let repository = try GitRepository(
            vaultURL: root,
            dataDirectory: dataDirectory
        )

        let (_, elapsed) = try await measure {
            try await repository.recordSnapshot()
        }
        print("GIT_10K_CORPUS_SNAPSHOT_MS \(milliseconds(elapsed))")
        #expect(
            elapsed < .seconds(10),
            "Exact notes snapshots must remain interactive for a representative large file count"
        )
    }

    @Test
    func `list files one item page avoids corpus-wide presentation formatting`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListFilesPerformanceTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("metadata-only".utf8)
        for index in 0..<2_000 {
            try payload.write(
                to: notes.appendingPathComponent(String(format: "%04d.md", index))
            )
        }
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
        ])
        let access = VaultAccessCoordinator(
            lockURL: root.appendingPathComponent(".vault-access.lock")
        )
        let lowLimitListing = VaultFileListingService(
            vaultPath: root.path,
            capabilities: capabilities,
            access: access,
            maximumScannedEntries: 1
        )
        await #expect(throws: FileListingError.self) {
            _ = try await lowLimitListing.list(ListFilesRequest(area: .notes, limit: 1))
        }

        let listing = VaultFileListingService(
            vaultPath: root.path,
            capabilities: capabilities,
            access: access
        )

        var samples: [Duration] = []
        for _ in 0..<5 {
            let (_, elapsed) = try await measure {
                try await listing.list(ListFilesRequest(area: .notes, limit: 1))
            }
            samples.append(elapsed)
        }
        let median = samples.sorted()[samples.count / 2]
        print("LIST_FILES_ONE_ITEM_MEDIAN_MS \(milliseconds(median))")
        #expect(median < .milliseconds(700))
    }

    @Test
    func `repeated outgoing links do not repeat ambiguous target resolution`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkQueryPerformanceTests-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<20 {
            let directory = notes.appendingPathComponent("folder-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("# Target".utf8).write(to: directory.appendingPathComponent("Target.md"))
        }
        let repeatedLinks = Array(repeating: "[[Target]]", count: 500)
            .joined(separator: "\n")
        try Data(repeatedLinks.utf8).write(to: notes.appendingPathComponent("source.md"))

        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
        ])
        let engine = VaultLinkQueryEngine(
            vaultPath: root.path,
            capabilities: capabilities,
            store: VaultCRUDStore(vaultPath: root.path),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )
        var samples: [Duration] = []
        for _ in 0..<5 {
            let (response, elapsed) = try await measure {
                try await engine.query(LinkQueryRequest(
                    direction: .outgoing,
                    target: "notes/source.md",
                    limit: 50
                ))
            }
            #expect(response.results.count == 50)
            samples.append(elapsed)
        }
        let median = samples.sorted()[samples.count / 2]
        print("QUERY_LINKS_REPEATED_TARGET_MEDIAN_MS \(milliseconds(median))")
        #expect(median < .milliseconds(75))
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
