import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Generic files — routed service` {
    private func runGit(_ arguments: [String], at root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: root)
        process.arguments = [
            "--git-dir=\(dataDirectory.snapshotRepositoryURL.path)",
            "--work-tree=\(root)",
            "-c", "core.bare=false",
        ] + arguments
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

    private func latestSnapshotReference(at root: String) throws -> String {
        try runGit([
            "for-each-ref",
            "--sort=-refname",
            "--count=1",
            "--format=%(refname)",
            GitRepository.snapshotReferencePrefix,
        ], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRuntime() async throws -> (String, VaultRuntime) {
        let root = NSTemporaryDirectory() + "VaultFileServiceTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)
        return (root, try await VaultRuntime.bootstrap(vaultPath: root))
    }

    @Test
    func `Read-only runtime neither initializes Git nor permits mutations`() async throws {
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
        let dataDirectory = try VaultDataDirectory.prepare(vaultPath: root)

        #expect(!FileManager.default.fileExists(atPath: root + "/.git"))
        #expect(
            !FileManager.default.fileExists(
                atPath: dataDirectory.snapshotRepositoryURL.path
            )
        )
        #expect(FileManager.default.fileExists(atPath: legacyCache))
        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.files.create(CreateFileRequest(

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

    @Test
    func `Runtime projects the complete capability matrix from registered bindings`() async throws {
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

        let markdownCreate = FileCreateContract(
            input: .content,
            transform: nil,
            acceptsTags: true
        )
        let pngCreate = FileCreateContract(
            input: .source,
            transform: nil,
            acceptsTags: false
        )
        let gifCreate = FileCreateContract(
            input: .source,
            transform: .videoToGIF,
            acceptsTags: false
        )

        #expect(runtime.capabilities == FileCapabilities(formats: [
            .init(
                format: .markdown,
                operations: textCRUD,
                createContract: markdownCreate,
                updateModes: Set(FileUpdateMode.allCases)
            ),
            .init(
                format: .canvas,
                operations: textCRUD,
                createContract: .content,
                updateModes: [.replace]
            ),
            .init(format: .har, operations: createReadDelete, createContract: .content),
            .init(format: .patch, operations: createReadDelete, createContract: .content),
            .init(
                format: .log,
                operations: textCRUD,
                createContract: .content,
                updateModes: [.append]
            ),
            .init(
                format: .json,
                operations: textCRUD,
                createContract: .content,
                updateModes: [.replace, .patch]
            ),
            .init(
                format: .csv,
                operations: textCRUD,
                createContract: .content,
                updateModes: Set(FileUpdateMode.allCases)
            ),
            .init(
                format: .png,
                operations: createReadDeleteMedia,
                createContract: pngCreate
            ),
            .init(format: .jpeg, operations: readDeleteMedia),
            .init(
                format: .gif,
                operations: createReadDeleteMedia,
                createContract: gifCreate
            ),
            .init(format: .webp, operations: readDeleteMedia),
            .init(format: .heic, operations: readDeleteMedia),
            .init(format: .tiff, operations: readDeleteMedia),
            .init(format: .bmp, operations: readDeleteMedia),
            .init(format: .pdf, operations: [
                .read: [.references],
            ]),
        ]))
    }

    @Test
    func `Create rejects fields outside the registered format contract`() async throws {
        let (root, runtime) = try await makeRuntime()
        let cases: [(CreateFileRequest, String)] = [
            (
                CreateFileRequest(
                    format: .json,
                    path: "notes/tagged.json",
                    content: "{}",
                    source: nil,
                    tags: ["ignored"],
                    transform: nil
                ),
                "Create contract for 'json' does not accept tags"
            ),
            (
                CreateFileRequest(
                    format: .markdown,
                    path: "notes/transformed.md",
                    content: "# Note",
                    source: nil,
                    tags: [],
                    transform: .videoToGIF
                ),
                "Create contract for 'markdown' does not accept transform"
            ),
            (
                CreateFileRequest(
                    format: .markdown,
                    path: "notes/conflicting.md",
                    content: "# Note",
                    source: "/tmp/also-a-source.md",
                    tags: [],
                    transform: nil
                ),
                "Create contract for 'markdown' does not accept source"
            ),
            (
                CreateFileRequest(
                    format: .png,
                    path: "notes/not-a-source.png",
                    content: "inline",
                    source: nil,
                    tags: [],
                    transform: nil
                ),
                "Create contract for 'png' requires source"
            ),
            (
                CreateFileRequest(
                    format: .gif,
                    path: "notes/untransformed.gif",
                    content: nil,
                    source: "/tmp/video.mov",
                    tags: [],
                    transform: nil
                ),
                "Create contract for 'gif' requires transform=video_to_gif"
            ),
        ]

        for (request, expectedError) in cases {
            do {
                _ = try await runtime.files.create(request)
                Issue.record("Expected create contract rejection for \(request.path)")
            } catch MutationFailure.beforePersistence(let cause) {
                #expect(cause is CreateFileContractValidator.Violation)
                #expect(String(describing: cause) == expectedError)
            } catch {
                Issue.record("Expected a preparation rejection, got: \(error)")
            }
            #expect(!FileManager.default.fileExists(atPath: root + "/" + request.path))
        }
    }

    @Test
    func `MCP discovery exposes only generic file CRUD`() async throws {
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

    @Test
    func `Markdown CRUD routes through generic storage and records snapshots`() async throws {
        let (root, runtime) = try await makeRuntime()
        let service = runtime.files
        let path = "notes/architecture.md"
        let create = CreateFileRequest(

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

        let snapshotReference = try latestSnapshotReference(at: root)
        let commitCount = try runGit(
            ["rev-list", "--count", snapshotReference, "--", path],
            at: root
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "2")

        _ = try await service.delete(DeleteFileRequest(

            expectedRevision: updatedRevision,
            format: .markdown,
            path: path
        ))
        #expect(!FileManager.default.fileExists(atPath: root + "/" + path))
        let deletionSnapshot = try latestSnapshotReference(at: root)
        #expect(
            try runGit(
                ["ls-tree", "-r", "--name-only", deletionSnapshot, "--", path],
                at: root
            ).isEmpty
        )
    }

    @Test
    func `No-op updates do not create empty commits`() async throws {
        let (root, runtime) = try await makeRuntime()
        let service = runtime.files
        let path = "notes/stable.md"
        let createOutput = try await service.create(CreateFileRequest(

            format: .markdown,
            path: path,
            content: "---\ntitle: Stable\n---\nunchanged",
            source: nil,
            tags: [],
            transform: nil
        ))

        let output = try await service.update(UpdateFileRequest(

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
        let snapshotReference = try latestSnapshotReference(at: root)
        let commitCount = try runGit(
            ["rev-list", "--count", snapshotReference, "--", path],
            at: root
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "1")
    }

    @Test
    func `Sensitive text is rejected before create or update persistence`() async throws {
        let (root, runtime) = try await makeRuntime()
        let rejectedPath = "notes/rejected.md"
        let secret = "Bearer " + String(repeating: "q", count: 32)

        await expectPreparationFailure(SensitiveContentPolicy.Violation.self) {
            _ = try await runtime.files.create(CreateFileRequest(

                format: .markdown,
                path: rejectedPath,
                content: secret,
                source: nil,
                tags: [],
                transform: nil
            ))
        }
        #expect(!FileManager.default.fileExists(
            atPath: root + "/" + rejectedPath
        ))

        let safePath = "notes/safe.md"
        let created = try await runtime.files.create(CreateFileRequest(

            format: .markdown,
            path: safePath,
            content: "safe content",
            source: nil,
            tags: [],
            transform: nil
        ))
        await expectPreparationFailure(SensitiveContentPolicy.Violation.self) {
            _ = try await runtime.files.update(UpdateFileRequest(

                expectedRevision: try #require(created.metadata?.revision),
                format: .markdown,
                path: safePath,
                content: secret,
                mode: .replace,
                replacements: []
            ))
        }
        #expect(try String(
            contentsOfFile: root + "/" + safePath,
            encoding: .utf8
        ).hasSuffix("safe content"))
        #expect(!FileManager.default.fileExists(atPath: root + "/.git"))
    }

    @Test
    func `Notes reads return the exact stored-byte revision`() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/revision.md"
        _ = try await runtime.files.create(CreateFileRequest(

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
    }

    @Test
    func `Runtime file operations create no redundant audit log`() async throws {
        let (root, runtime) = try await makeRuntime()
        let dataDirectory = try VaultDataDirectory.prepare(
            vaultPath: root
        )
        let path = "notes/no-audit.md"

        _ = try await runtime.files.create(CreateFileRequest(

            format: .markdown,
            path: path,
            content: "Git is the operation history",
            source: nil,
            tags: [],
            transform: nil
        ))
        _ = try await runtime.files.read(ReadFileRequest(
            format: .markdown,
            path: path,
            options: .default
        ))

        #expect(!FileManager.default.fileExists(
            atPath: dataDirectory.rootURL.appendingPathComponent("audit.log").path
        ))
    }

    @Test
    func `A note changed while its reader runs returns no mismatched revision`() async throws {
        let root = NSTemporaryDirectory()
            + "VaultFileServiceReadRace-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        let path = "notes/race.md"
        try Data("before".utf8).write(to: URL(fileURLWithPath: root + "/" + path))
        let dataDirectory = try makeTestDataDirectory(vaultPath: root)
        let store = VaultCRUDStore(vaultPath: root)
        let catalog = FileFormatCatalog(definitions: [
            FileFormatDefinition(
                format: .markdown,
                operations: FormatOperations(
                    create: nil,
                    read: ReadOperationBinding(
                        allowedAreas: [.notes],
                        execute: { _, target, snapshot in
                            try Data("during".utf8).write(
                                to: target.url,
                                options: .atomic
                            )
                            let returned = String(
                                decoding: snapshot.data,
                                as: UTF8.self
                            )
                            try Data("before".utf8).write(
                                to: target.url,
                                options: .atomic
                            )
                            return .text(returned)
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
                versioning: try GitRepository(
                    vaultURL: URL(fileURLWithPath: root, isDirectory: true),
                    dataDirectory: dataDirectory
                )
            ),
            access: VaultAccessCoordinator(
                lockURL: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-access.lock")
            )
        )

        let output = try await service.read(ReadFileRequest(
            format: .markdown,
            path: path,
            options: .default
        ))
        guard case .text(let returned) = output.contents.first else {
            Issue.record("Expected text output")
            return
        }
        #expect(
            output.metadata?.revision
                == FileSnapshot(data: Data(returned.utf8), modifiedDate: nil).revision
        )
        #expect(
            try String(contentsOfFile: root + "/" + path, encoding: .utf8) == "before"
        )
    }

    @Test
    func `Stale update and delete revisions fail without exposing the current revision`() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/stale.md"
        let created = try await runtime.files.create(CreateFileRequest(

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

                        expectedRevision: staleRevision,
                        format: .markdown,
                        path: path,
                        content: "overwrite",
                        mode: .replace,
                        replacements: []
                    ))
                case .delete:
                    _ = try await runtime.files.delete(DeleteFileRequest(

                        expectedRevision: staleRevision,
                        format: .markdown,
                        path: path
                    ))
                case .create, .read:
                    Issue.record("Unexpected test operation")
                }
                Issue.record("Expected a revision conflict")
            } catch MutationFailure.beforePersistence(let cause) {
                guard let routing = cause as? FileRoutingError,
                      case .revisionConflict(let conflictPath) = routing else {
                    Issue.record("Expected revision-conflict cause, got: \(cause)")
                    continue
                }
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

    @Test
    func `Existing-file rejection leaves a later create independent`() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/existing.md"
        _ = try await runtime.files.create(CreateFileRequest(

            format: .markdown,
            path: path,
            content: "first",
            source: nil,
            tags: [],
            transform: nil
        ))
        let retryable = CreateFileRequest(

            format: .markdown,
            path: path,
            content: "second",
            source: nil,
            tags: [],
            transform: nil
        )

        await expectPreparationFailure(VaultCRUDStore.StoreError.self) {
            _ = try await runtime.files.create(retryable)
        }
        try FileManager.default.removeItem(atPath: root + "/" + path)

        _ = try await runtime.files.create(retryable)
        #expect(try String(
            contentsOfFile: root + "/" + path,
            encoding: .utf8
        ).hasSuffix("second"))
    }

    @Test
    func `Concurrent updates from one revision admit exactly one winner`() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/concurrent.md"
        let created = try await runtime.files.create(CreateFileRequest(

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

                        expectedRevision: baseRevision,
                        format: .markdown,
                        path: path,
                        content: content,
                        mode: .replace,
                        replacements: []
                    ))
                    return true
                } catch MutationFailure.beforePersistence(let cause) {
                    guard let routing = cause as? FileRoutingError,
                          case .revisionConflict = routing else { throw cause }
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
            [
                "rev-list", "--count",
                try latestSnapshotReference(at: root), "--", path,
            ],
            at: root
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(commitCount == "2")
        #expect(!FileManager.default.fileExists(atPath: root + "/.git"))
    }

    @Test
    func `Default stored text read is bounded instead of returning the full large file`() async throws {
        let (_, runtime) = try await makeRuntime()
        let path = "notes/large.md"
        _ = try await runtime.files.create(CreateFileRequest(
            format: .markdown,
            path: path,
            content: String(repeating: "a", count: 128 * 1_024),
            source: nil,
            tags: [],
            transform: nil
        ))

        let output = try await runtime.files.read(ReadFileRequest(
            format: .markdown,
            path: path,
            options: .default
        ))
        guard case .text(let text) = output.contents.first else {
            Issue.record("Expected text output")
            return
        }

        #expect(text.utf8.count <= 64 * 1_024)
        let revision = try #require(output.metadata?.revision)
        let window = try #require(output.textWindow)
        #expect(window.byteOffset == 0)
        #expect(window.byteCount == text.utf8.count)
        #expect(window.totalBytes > window.byteCount)
        let nextOffset = try #require(window.nextByteOffset)

        let continuation = try await runtime.files.read(ReadFileRequest(
            format: .markdown,
            path: path,
            options: ReadFileOptions(
                byteOffset: nextOffset,
                expectedRevision: revision
            )
        ))
        guard case .text(let continuedText) = continuation.contents.first else {
            Issue.record("Expected continuation text output")
            return
        }
        #expect(continuedText.utf8.count <= 64 * 1_024)
        #expect(continuation.metadata?.revision == revision)
        #expect(continuation.textWindow?.byteOffset == nextOffset)
    }

    @Test
    func `Text continuation rejects a changed exact-byte revision`() async throws {
        let (root, runtime) = try await makeRuntime()
        let path = "notes/changing.md"
        _ = try await runtime.files.create(CreateFileRequest(
            format: .markdown,
            path: path,
            content: String(repeating: "a", count: 80 * 1_024),
            source: nil,
            tags: [],
            transform: nil
        ))
        let first = try await runtime.files.read(ReadFileRequest(
            format: .markdown,
            path: path,
            options: .default
        ))
        let revision = try #require(first.metadata?.revision)
        let nextOffset = try #require(first.textWindow?.nextByteOffset)
        try Data(String(repeating: "b", count: 80 * 1_024).utf8).write(
            to: URL(fileURLWithPath: root + "/" + path),
            options: .atomic
        )

        await #expect(throws: FileRoutingError.self) {
            try await runtime.files.read(ReadFileRequest(
                format: .markdown,
                path: path,
                options: ReadFileOptions(
                    byteOffset: nextOffset,
                    expectedRevision: revision
                )
            ))
        }
    }

    @Test
    func `Read selectors reject unsafe continuations and conflicting modes`() async throws {
        let (_, runtime) = try await makeRuntime()
        let invalidRequests: [(ReadFileRequest, String)] = [
            (
                ReadFileRequest(
                    format: .markdown,
                    path: "notes/missing.md",
                    options: ReadFileOptions(byteOffset: 1)
                ),
                "requires expected_revision"
            ),
            (
                ReadFileRequest(
                    format: .markdown,
                    path: "notes/missing.md",
                    options: ReadFileOptions(tailLines: 10)
                ),
                "log line selectors"
            ),
            (
                ReadFileRequest(
                    format: .log,
                    path: "notes/missing.log",
                    options: ReadFileOptions(tailLines: 10, byteOffset: 0)
                ),
                "log line selectors"
            ),
            (
                ReadFileRequest(
                    format: .pdf,
                    path: "references/missing.pdf",
                    options: ReadFileOptions(maxBytes: 1_024)
                ),
                "UTF-8 text reads"
            ),
            (
                ReadFileRequest(
                    format: .json,
                    path: "notes/missing.json",
                    options: ReadFileOptions(
                        maxBytes: FileReadRequestLimits.maximumTextChunkBytes + 1
                    )
                ),
                "max_bytes"
            ),
        ]

        for (request, expectedMessage) in invalidRequests {
            do {
                _ = try await runtime.files.read(request)
                Issue.record("Expected invalid read options")
            } catch let error as FileRoutingError {
                #expect(error.description.contains(expectedMessage))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func `Unsupported operation is rejected before touching disk`() async throws {
        let (root, runtime) = try await makeRuntime()
        let service = runtime.files
        let request = UpdateFileRequest(

            expectedRevision: revision("missing"),
            format: .har,
            path: "notes/capture.har",
            content: "{}",
            mode: .replace,
            replacements: []
        )
        await expectPreparationFailure(FileRoutingError.self) {
            _ = try await service.update(request)
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/notes/capture.har"))
    }

    @Test
    func `Every mutation routes through the writable target boundary`() async throws {
        let (_, runtime) = try await makeRuntime()
        let service = runtime.files

        await expectAreaNotWritable("references/create.md") {
            try await service.create(CreateFileRequest(

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

                expectedRevision: revision("blocked"),
                format: .pdf,
                path: "references/delete.pdf"
            ))
        }
    }

    @Test
    func `Delete hooks can reject before persistence`() async throws {
        let root = NSTemporaryDirectory() + "VaultFileServiceDeleteHook-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        let path = "notes/protected.md"
        try Data("protected".utf8).write(to: URL(fileURLWithPath: root + "/" + path))

        let delete = DeleteOperationBinding(
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
        let store = VaultCRUDStore(vaultPath: root)
        let service = VaultFileService(
            vaultPath: root,
            catalog: catalog,
            store: store,
            mutations: VaultMutationExecutor(
                versioning: try GitRepository(
                    vaultURL: URL(fileURLWithPath: root, isDirectory: true),
                    dataDirectory: dataDirectory
                )
            ),
            access: VaultAccessCoordinator(
                lockURL: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("vault-access.lock")
            )
        )

        await expectPreparationFailure(DeleteHookError.self) {
            _ = try await service.delete(DeleteFileRequest(

                expectedRevision: revision("protected"),
                format: .markdown,
                path: path
            ))
        }
        #expect(FileManager.default.fileExists(atPath: root + "/" + path))
    }

    @Test
    func `Markdown metadata view returns bounded facts and no note content`() async throws {
        let (root, runtime) = try await makeRuntime()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let markdown = """
        ---
        title: "Agent Map"
        tags: [Swift, architecture]
        ---

        # Ignored fallback
        Alpha beta [[Local Note|alias]] [internal](projects/next.md) [web](https://example.com).
        """
        try Data(markdown.utf8).write(
            to: URL(fileURLWithPath: root + "/notes/agent-map.md")
        )

        let output = try await runtime.files.read(ReadFileRequest(
            format: .markdown,
            path: "notes/agent-map.md",
            options: ReadFileOptions(view: .metadata)
        ))

        #expect(output.contents.isEmpty)
        let metadata = try #require(output.readMetadata)
        #expect(metadata.format == .markdown)
        #expect(metadata.title == "Agent Map")
        #expect(metadata.tags == ["architecture", "swift"])
        #expect(metadata.wordCount == 9)
        #expect(metadata.outgoingLinkTargets == ["Local Note", "projects/next.md"])
        #expect(metadata.byteCount == Data(markdown.utf8).count)
        #expect(output.metadata?.revision != nil)

        await #expect(throws: FileRoutingError.self) {
            _ = try await runtime.files.read(ReadFileRequest(
                format: .markdown,
                path: "notes/agent-map.md",
                options: ReadFileOptions(
                    view: .metadata,
                    byteOffset: 4
                )
            ))
        }
    }

    @Test
    func `PDF metadata view returns document structure without pages or images`() async throws {
        let (root, runtime) = try await makeRuntime()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let data = try generatedSearchPDF(pages: ["first", "second"])
        try data.write(
            to: URL(fileURLWithPath: root + "/references/manual.pdf")
        )

        let output = try await runtime.files.read(ReadFileRequest(
            format: .pdf,
            path: "references/manual.pdf",
            options: ReadFileOptions(view: .metadata)
        ))

        #expect(output.contents.isEmpty)
        let metadata = try #require(output.readMetadata)
        #expect(metadata.format == .pdf)
        #expect(metadata.pageCount == 2)
        #expect(metadata.pageLabels?.count == 2)
        #expect(metadata.byteCount == data.count)
        #expect(output.metadata?.revision == nil)
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
        } catch MutationFailure.beforePersistence(let cause) {
            guard let routing = cause as? FileRoutingError,
                  case .areaNotWritable(let path) = routing else {
                Issue.record("Expected writable-area rejection cause, got: \(cause)")
                return
            }
            #expect(path == expectedPath)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
