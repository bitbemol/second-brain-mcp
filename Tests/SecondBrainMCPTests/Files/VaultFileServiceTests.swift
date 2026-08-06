import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Generic files — routed service")
struct VaultFileServiceTests {
    private func runGit(_ arguments: [String], at root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitInspectionError.commandFailed
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private func makeRuntime() async throws -> (String, VaultRuntime) {
        let root = NSTemporaryDirectory() + "VaultFileServiceTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)
        return (root, try await VaultRuntime.bootstrap(vaultPath: root))
    }

    @Test("Read-only runtime neither initializes Git nor permits mutations")
    func readOnlyRuntimeDoesNotMutateVault() async throws {
        let root = NSTemporaryDirectory()
            + "VaultFileServiceTests-read-only-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: root + "/references",
            withIntermediateDirectories: true
        )
        let legacyCache = root + "/.secondbrain-mcp/cache"
        try FileManager.default.createDirectory(
            atPath: legacyCache,
            withIntermediateDirectories: true
        )

        let runtime = try await VaultRuntime.bootstrap(
            vaultPath: root,
            readOnly: true
        )

        #expect(!FileManager.default.fileExists(atPath: root + "/.git"))
        #expect(FileManager.default.fileExists(atPath: legacyCache))
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.files.create(CreateFileRequest(
                mutationID: MutationID(),
                format: .markdown,
                path: "notes/blocked.md",
                content: "blocked",
                source: nil,
                tags: [],
                transform: nil
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/blocked.md"))
    }

    @Test("Runtime projects the complete capability matrix from registered bindings")
    func capabilities() async throws {
        let (_, runtime) = try await makeRuntime()
        let notes: Set<VaultArea> = [.notes]
        let readableMedia: Set<VaultArea> = [.notes, .references]
        let textCRUD: [FileCRUDOperation: Set<VaultArea>] = [
            .create: notes,
            .read: notes,
            .update: notes,
            .delete: notes,
        ]
        let createReadDelete: [FileCRUDOperation: Set<VaultArea>] = [
            .create: notes,
            .read: notes,
            .delete: notes,
        ]
        let readDeleteMedia: [FileCRUDOperation: Set<VaultArea>] = [
            .read: readableMedia,
            .delete: notes,
        ]
        let createReadDeleteMedia: [FileCRUDOperation: Set<VaultArea>] = [
            .create: notes,
            .read: readableMedia,
            .delete: notes,
        ]

        #expect(runtime.capabilities == FileCapabilities(formats: [
            .init(format: .markdown, operations: textCRUD),
            .init(format: .canvas, operations: textCRUD),
            .init(format: .har, operations: createReadDelete),
            .init(format: .patch, operations: createReadDelete),
            .init(format: .log, operations: textCRUD),
            .init(format: .json, operations: textCRUD),
            .init(format: .csv, operations: textCRUD),
            .init(format: .png, operations: createReadDeleteMedia),
            .init(format: .jpeg, operations: readDeleteMedia),
            .init(format: .gif, operations: createReadDeleteMedia),
            .init(format: .webp, operations: readDeleteMedia),
            .init(format: .heic, operations: readDeleteMedia),
            .init(format: .tiff, operations: readDeleteMedia),
            .init(format: .bmp, operations: readDeleteMedia),
            .init(format: .pdf, operations: [
                .read: [.references],
            ]),
        ]))
    }

    @Test("MCP discovery exposes only generic file CRUD")
    func compactMCPSurface() async throws {
        let (_, runtime) = try await makeRuntime()
        let capabilities = runtime.capabilities
        let tools = FileToolDefinitions.build(
            capabilities: capabilities,
            readOnly: false
        )
        let names = Set(tools.map(\.name))
        let genericCRUD: Set<String> = ["create_file", "read_file", "update_file", "delete_file"]

        #expect(names == genericCRUD)
        #expect(tools.map(\.name) == FileToolName.allCases.map(\.rawValue))
        for tool in tools {
            let schema = try #require(tool.inputSchema.objectValue)
            let properties = try #require(schema["properties"]?.objectValue)
            #expect(properties["format"] != nil)
            #expect(properties["path"] != nil)
            let required = Set(
                schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            #expect(required.isSuperset(of: ["format", "path"]))
        }

        let readOnlyTools = FileToolDefinitions.build(
            capabilities: capabilities,
            readOnly: true
        )
        #expect(readOnlyTools.map(\.name) == [FileToolName.read.rawValue])
    }

    @Test("MCP resources expose only file capabilities")
    func compactResourceSurface() {
        let uris = Set(FileCapabilitiesResource.list().map(\.uri))
        #expect(uris == ["secondbrain://file-capabilities"])
    }

    @Test("Read-only capability resource omits every mutation")
    func readOnlyCapabilityResource() async throws {
        let (_, runtime) = try await makeRuntime()
        let result = try FileCapabilitiesResource.read(
            capabilities: runtime.capabilities,
            readOnly: true
        )
        let json = try #require(result.contents.first?.text)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let entries = try #require(object as? [[String: Any]])
        let markdown = try #require(entries.first { $0["format"] as? String == "markdown" })
        let operations = try #require(markdown["operations"] as? [String: Any])
        let read = try #require(operations["read"] as? [String: Any])

        #expect(markdown["extensions"] as? [String] == ["markdown", "md"])
        #expect(Set(operations.keys) == ["read"])
        #expect(read["areas"] as? [String] == ["notes"])
    }

    @Test("Markdown CRUD routes through generic storage and creates git commits")
    func markdownLifecycle() async throws {
        let (root, runtime) = try await makeRuntime()
        let service = runtime.files
        let path = "notes/architecture.md"
        let create = CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "# Architecture\nInitial",
            source: nil,
            tags: ["design"],
            transform: nil
        )
        let createOutput = try await service.create(create)
        let createdRevision = try #require(createOutput.metadata?.revision)
        let created = try String(contentsOfFile: root + "/" + path, encoding: .utf8)
        #expect(created.contains("tags: [\"design\"]"))

        let update = UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: createdRevision,
            format: .markdown,
            path: path,
            content: "Updated",
            mode: .append,
            replacements: []
        )
        let updateOutput = try await service.update(update)
        let updatedRevision = try #require(updateOutput.metadata?.revision)
        #expect(try String(contentsOfFile: root + "/" + path, encoding: .utf8).hasSuffix("Updated"))

        let commitCount = try runGit(["rev-list", "--count", "HEAD", "--", path], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "2")

        _ = try await service.delete(DeleteFileRequest(
            mutationID: MutationID(),
            expectedRevision: updatedRevision,
            format: .markdown,
            path: path
        ))
        #expect(!FileManager.default.fileExists(atPath: root + "/" + path))
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("No-op updates do not create empty commits")
    func noOpUpdate() async throws {
        let (root, runtime) = try await makeRuntime()
        let service = runtime.files
        let path = "notes/stable.md"
        let createOutput = try await service.create(CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "---\ntitle: Stable\n---\nunchanged",
            source: nil,
            tags: [],
            transform: nil
        ))

        let output = try await service.update(UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: try #require(createOutput.metadata?.revision),
            format: .markdown,
            path: path,
            content: "---\ntitle: Stable\n---\nunchanged",
            mode: .replace,
            replacements: []
        ))
        guard case .text(let message) = output.contents.first else {
            Issue.record("Expected no-op result text")
            return
        }

        #expect(message.contains("No changes"))
        let commitCount = try runGit(["rev-list", "--count", "HEAD", "--", path], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "1")
    }

    @Test("Notes reads return the exact stored-byte revision")
    func noteReadReturnsRevision() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/revision.md"
        _ = try await runtime.files.create(CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "revision body",
            source: nil,
            tags: [],
            transform: nil
        ))

        let output = try await runtime.files.read(ReadFileRequest(
            format: .markdown,
            path: path,
            options: .default
        ))
        let stored = try Data(contentsOf: URL(fileURLWithPath: root + "/" + path))

        #expect(output.metadata?.path == path)
        #expect(output.metadata?.area == .notes)
        #expect(output.metadata?.revision == FileSnapshot(
            data: stored,
            modifiedDate: nil
        ).revision)
        #expect(output.metadata?.mutationID == nil)
        #expect(output.metadata?.replayed == false)
    }

    @Test("A note changed while its reader runs returns no mismatched revision")
    func noteChangedDuringReadIsRejected() async throws {
        let root = NSTemporaryDirectory()
            + "VaultFileServiceReadRace-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        let path = "notes/race.md"
        try Data("before".utf8).write(to: URL(fileURLWithPath: root + "/" + path))
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let audit = AuditLogger(dataDirectory: dataDirectory)
        let store = VaultCRUDStore(vaultPath: root)
        let catalog = FileFormatCatalog(definitions: [
            FileFormatDefinition(
                format: .markdown,
                operations: FormatOperations(
                    create: nil,
                    read: ReadOperationBinding(
                        id: .markdown,
                        allowedAreas: [.notes],
                        execute: { _, target in
                            try Data("after".utf8).write(
                                to: target.url,
                                options: .atomic
                            )
                            return .text("before")
                        }
                    ),
                    update: nil,
                    delete: nil
                )
            )
        ])
        let service = VaultFileService(
            vaultPath: root,
            catalog: catalog,
            store: store,
            mutations: VaultMutationExecutor(
                git: GitRepository(repoPath: root),
                audit: audit,
                processMutationLock: POSIXAdvisoryFileLock(
                    url: dataDirectory.lockDirectoryURL
                        .appendingPathComponent("vault-mutations.lock")
                ),
                receipts: MutationReceiptStore(dataDirectory: dataDirectory)
            ),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: dataDirectory.lockDirectoryURL
            ),
            audit: audit
        )

        do {
            _ = try await service.read(ReadFileRequest(
                format: .markdown,
                path: path,
                options: .default
            ))
            Issue.record("Expected an unstable read to be rejected")
        } catch FileRoutingError.changedDuringRead(let changedPath) {
            #expect(changedPath == path)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Stale update and delete revisions fail without exposing the current revision")
    func staleMutationRevisionsFailClosed() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/stale.md"
        let created = try await runtime.files.create(CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "original",
            source: nil,
            tags: [],
            transform: nil
        ))
        let staleRevision = try #require(created.metadata?.revision)
        try Data("external change".utf8).write(
            to: URL(fileURLWithPath: root + "/" + path),
            options: .atomic
        )
        let currentRevision = revision("external change")

        for operation in [FileCRUDOperation.update, .delete] {
            do {
                switch operation {
                case .update:
                    _ = try await runtime.files.update(UpdateFileRequest(
                        mutationID: MutationID(),
                        expectedRevision: staleRevision,
                        format: .markdown,
                        path: path,
                        content: "overwrite",
                        mode: .replace,
                        replacements: []
                    ))
                case .delete:
                    _ = try await runtime.files.delete(DeleteFileRequest(
                        mutationID: MutationID(),
                        expectedRevision: staleRevision,
                        format: .markdown,
                        path: path
                    ))
                case .create, .read:
                    Issue.record("Unexpected test operation")
                }
                Issue.record("Expected a revision conflict")
            } catch FileRoutingError.revisionConflict(let conflictPath) {
                #expect(conflictPath == path)
                #expect(!String(describing: FileRoutingError.revisionConflict(
                    conflictPath
                )).contains(currentRevision.rawValue))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        #expect(try String(
            contentsOfFile: root + "/" + path,
            encoding: .utf8
        ) == "external change")
    }

    @Test("Identical mutation retry replays one durable outcome")
    func mutationRetryIsIdempotent() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/replayed.md"
        let request = CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "one write",
            source: nil,
            tags: [],
            transform: nil
        )

        let first = try await runtime.files.create(request)
        let replay = try await runtime.files.create(request)

        #expect(first.metadata?.replayed == false)
        #expect(replay.metadata?.replayed == true)
        #expect(replay.metadata?.revision == first.metadata?.revision)
        #expect(try String(
            contentsOfFile: root + "/" + path,
            encoding: .utf8
        ).hasSuffix("one write"))
        let commitCount = try runGit(
            ["rev-list", "--count", "HEAD", "--", path],
            at: root
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "1")
    }

    @Test("Existing-file rejection does not poison its mutation ID")
    func existingCreateCanRetryAfterValidationFailure() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/existing.md"
        _ = try await runtime.files.create(CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "first",
            source: nil,
            tags: [],
            transform: nil
        ))
        let retryable = CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "second",
            source: nil,
            tags: [],
            transform: nil
        )

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            _ = try await runtime.files.create(retryable)
        }
        try FileManager.default.removeItem(atPath: root + "/" + path)

        let output = try await runtime.files.create(retryable)
        #expect(output.metadata?.replayed == false)
        #expect(try String(
            contentsOfFile: root + "/" + path,
            encoding: .utf8
        ).hasSuffix("second"))
    }

    @Test("Concurrent updates from one revision admit exactly one winner")
    func concurrentUpdatesConflict() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/concurrent.md"
        let created = try await runtime.files.create(CreateFileRequest(
            mutationID: MutationID(),
            format: .markdown,
            path: path,
            content: "base",
            source: nil,
            tags: [],
            transform: nil
        ))
        let baseRevision = try #require(created.metadata?.revision)

        let attempts = ["agent-a", "agent-b"].map { content in
            Task {
                do {
                    _ = try await runtime.files.update(UpdateFileRequest(
                        mutationID: MutationID(),
                        expectedRevision: baseRevision,
                        format: .markdown,
                        path: path,
                        content: content,
                        mode: .replace,
                        replacements: []
                    ))
                    return true
                } catch FileRoutingError.revisionConflict {
                    return false
                }
            }
        }
        var outcomes: [Bool] = []
        for attempt in attempts {
            outcomes.append(try await attempt.value)
        }

        #expect(outcomes.filter { $0 }.count == 1)
        let stored = try String(
            contentsOfFile: root + "/" + path,
            encoding: .utf8
        )
        #expect(stored == "agent-a" || stored == "agent-b")
        let commitCount = try runGit(
            ["rev-list", "--count", "HEAD", "--", path],
            at: root
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "2")
        #expect(try runGit(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test("Unsupported operation is rejected before touching disk")
    func unsupportedUpdate() async throws {
        let (root, runtime) = try await makeRuntime()
        let service = runtime.files
        let request = UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: revision("missing"),
            format: .har,
            path: "notes/capture.har",
            content: "{}",
            mode: .replace,
            replacements: []
        )
        await #expect(throws: FileRoutingError.self) {
            try await service.update(request)
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/capture.har"))
    }

    @Test("Every mutation routes through the writable target boundary")
    func mutationAreaBoundary() async throws {
        let (_, runtime) = try await makeRuntime()
        let service = runtime.files

        await expectAreaNotWritable("references/create.md") {
            try await service.create(CreateFileRequest(
                mutationID: MutationID(),
                format: .markdown,
                path: "references/create.md",
                content: "blocked",
                source: nil,
                tags: [],
                transform: nil
            ))
        }
        await expectAreaNotWritable("references/update.md") {
            try await service.update(UpdateFileRequest(
                mutationID: MutationID(),
                expectedRevision: revision("blocked"),
                format: .markdown,
                path: "references/update.md",
                content: "blocked",
                mode: .replace,
                replacements: []
            ))
        }
        await expectAreaNotWritable("references/delete.pdf") {
            try await service.delete(DeleteFileRequest(
                mutationID: MutationID(),
                expectedRevision: revision("blocked"),
                format: .pdf,
                path: "references/delete.pdf"
            ))
        }
    }

    @Test("Delete hooks can reject before persistence")
    func deleteHookPrecedesPersistence() async throws {
        let root = NSTemporaryDirectory() + "VaultFileServiceDeleteHook-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        let path = "notes/protected.md"
        try Data("protected".utf8).write(to: URL(fileURLWithPath: root + "/" + path))

        let delete = DeleteOperationBinding(
            id: .softDelete,
            allowedAreas: [.notes],
            execute: { _, _ in throw DeleteHookError.rejected }
        )
        let catalog = FileFormatCatalog(definitions: [
            FileFormatDefinition(
                format: .markdown,
                operations: FormatOperations(
                    create: nil,
                    read: nil,
                    update: nil,
                    delete: delete
                )
            )
        ])
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let audit = AuditLogger(dataDirectory: dataDirectory)
        let store = VaultCRUDStore(vaultPath: root)
        let service = VaultFileService(
            vaultPath: root,
            catalog: catalog,
            store: store,
            mutations: VaultMutationExecutor(
                git: GitRepository(repoPath: root),
                audit: audit,
                processMutationLock: POSIXAdvisoryFileLock(
                    url: dataDirectory.lockDirectoryURL
                        .appendingPathComponent("vault-mutations.lock")
                ),
                receipts: MutationReceiptStore(dataDirectory: dataDirectory)
            ),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: dataDirectory.lockDirectoryURL
            ),
            audit: audit
        )

        await #expect(throws: DeleteHookError.self) {
            try await service.delete(DeleteFileRequest(
                mutationID: MutationID(),
                expectedRevision: revision("protected"),
                format: .markdown,
                path: path
            ))
        }
        #expect(FileManager.default.fileExists(atPath: root + "/" + path))
    }

    private enum GitInspectionError: Error {
        case commandFailed
    }

    private enum DeleteHookError: Error {
        case rejected
    }

    private func revision(_ text: String) -> FileRevision {
        FileSnapshot(data: Data(text.utf8), modifiedDate: nil).revision
    }

    private func expectAreaNotWritable(
        _ expectedPath: String,
        operation: () async throws -> FileOperationOutput
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected writable-area rejection")
        } catch FileRoutingError.areaNotWritable(let path) {
            #expect(path == expectedPath)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
