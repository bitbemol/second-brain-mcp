import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("Routine tool failures have safe recovery contracts")
struct RoutineToolErrorTests {
    @Test("Duplicate create reports ALREADY_EXISTS without changing bytes")
    func duplicateCreateIsActionable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.create()
        let result = try await fixture.create()
        try expectFailure(result, code: "ALREADY_EXISTS", state: "not_applied",
                          retry: "correct_request", detail: "already exists")
        #expect(try Data(contentsOf: fixture.file) == Data("{}".utf8))
        #expect(await fixture.versioning.calls == 1)
    }

    @Test("Old paths after a real move return NOT_FOUND for read and delete")
    func movedSourceIsNotFound() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let created = try await fixture.create()
        let revision = try #require(created.structuredContent?.objectValue?["revision"]?.stringValue)
        let moved = try await PathMoveToolController(readOnly: false, paths: fixture.paths).call(.init(
            name: "move_path", arguments: [
                "kind": .string("file"), "format": .string("json"),
                "source_path": .string("notes/source.json"), "destination_path": .string("notes/moved.json"),
                "expected_revision": .string(revision),
            ]
        ))
        try #require(moved.isError != true)
        try await expectMissingReadAndDelete(fixture, revision: revision)
        #expect(try Data(contentsOf: fixture.vault.appendingPathComponent("notes/moved.json")) == Data("{}".utf8))
        #expect(await fixture.versioning.calls == 2)
    }

    @Test("Previously deleted paths return NOT_FOUND without a second deletion")
    func deletedSourceIsNotFound() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let created = try await fixture.create()
        let revision = try #require(created.structuredContent?.objectValue?["revision"]?.stringValue)
        let deleted = try await fixture.call("delete_file", revision: revision)
        try #require(deleted.isError != true)
        try await expectMissingReadAndDelete(fixture, revision: revision)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(await fixture.versioning.calls == 2)
    }

    @Test("An explicit missing list directory reports DIRECTORY_NOT_FOUND")
    func missingListDirectoryIsActionable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = ListFilesToolController(listing: fixture.listing)
        let result = try await controller.call(.init(name: "list_files", arguments: [
            "area": .string("notes"), "directory": .string("PRIVATE_ERROR_MARKER-missing"),
        ]))
        try expectFailure(result, code: "DIRECTORY_NOT_FOUND", state: "read_only",
                          retry: "correct_request", detail: "directory")
        let absentArea = try await controller.call(.init(
            name: "list_files", arguments: ["area": .string("references")]
        ))
        #expect(absentArea.isError != true)
        #expect(absentArea.structuredContent?.objectValue?["files"]?.arrayValue?.isEmpty == true)
    }

    @Test("Traversal errors are typed and never echo hostile paths")
    func traversalErrorsArePrivateAcrossTools() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hostile = "notes/../PRIVATE_ERROR_MARKER.json"
        let read = try await fixture.controller.call(.init(name: "read_file", arguments: [
            "format": .string("json"), "path": .string(hostile),
        ]))
        try expectFailure(read, code: "INVALID_PATH", state: "read_only",
                          retry: "correct_request", detail: "traversal")
        let create = try await fixture.controller.call(.init(name: "create_file", arguments: [
            "format": .string("json"), "path": .string(hostile), "content": .string("{}"),
        ]))
        try expectFailure(create, code: "INVALID_PATH", state: "not_applied",
                          retry: "correct_request", detail: "traversal")
        let listing = try await ListFilesToolController(listing: fixture.listing).call(.init(
            name: "list_files", arguments: [
                "area": .string("notes"), "directory": .string("../PRIVATE_ERROR_MARKER"),
            ]
        ))
        try expectFailure(listing, code: "INVALID_PATH", state: "read_only",
                          retry: "correct_request", detail: "traversal")
        #expect(await fixture.versioning.calls == 0)
    }

    @Test("Missing GIF transform is diagnosed before the external source is read")
    func missingGIFTransformIsActionable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.controller.call(.init(name: "create_file", arguments: [
            "format": .string("gif"), "path": .string("notes/import.gif"),
            "source": .string("/missing/PRIVATE_ERROR_MARKER.mov"),
        ]))
        try expectFailure(result, code: "MISSING_TRANSFORM", state: "not_applied",
                          retry: "correct_request", detail: "video_to_gif")
        #expect(await fixture.versioning.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.vault.appendingPathComponent("notes/import.gif").path))
    }

    @Test("Malformed arguments are known not to have reached the mutation")
    func decodingRejectionIsNotApplied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.controller.call(.init(name: "create_file", arguments: [
            "format": .string("json"), "path": .string("notes/source.json"), "content": .int(4),
        ]))
        try expectFailure(result, code: "INVALID_REQUEST", state: "not_applied",
                          retry: "correct_request", detail: "expected string")
        #expect(await fixture.versioning.calls == 0)
    }

    @Test("Snapshot failures after real persistence never claim no change",
          arguments: ["unknown", "snapshot", "path"])
    func persistedMutationFailureRemainsUncertain(_ kind: String) async throws {
        let failure: any Error
        let expectedCode: String
        switch kind {
        case "snapshot":
            failure = VaultVersioningError.gitCommandFailed(
                arguments: ["/private/PRIVATE_ERROR_MARKER"], status: "PRIVATE_ERROR_MARKER",
                message: "/private/PRIVATE_ERROR_MARKER"
            )
            expectedCode = "SNAPSHOT_FAILED"
        case "path":
            // A safe error type is not proof that the mutation was rejected before persistence.
            failure = PathValidationError.pathContainsTraversal("/private/PRIVATE_ERROR_MARKER")
            expectedCode = "INVALID_PATH"
        default:
            failure = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSLocalizedDescriptionKey: "/private/PRIVATE_ERROR_MARKER"])
            expectedCode = "INTERNAL_ERROR"
        }
        let fixture = try Fixture(snapshotFailure: failure)
        defer { fixture.cleanup() }
        let result = try await fixture.create()
        try expectFailure(result, code: expectedCode, state: "unknown",
                          retry: "inspect_state", detail: "inspect")
        #expect(try Data(contentsOf: fixture.file) == Data("{}".utf8))
        #expect(await fixture.versioning.calls == 1)
        #expect(!text(result).lowercased().contains("not applied"))
        #expect(!text(result).lowercased().contains("unchanged"))
    }


    @Test("Malformed HAR is a private, actionable rejection before persistence",
          arguments: ["{}", "{\"log\":{}}", "not JSON", "{\"log\":{\"version\":\"1.2\"}}"])
    func malformedHARIsRejected(_ content: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.controller.call(.init(name: "create_file", arguments: [
            "format": .string("har"), "path": .string("notes/invalid.har"), "content": .string(content),
        ]))
        try expectFailure(result, code: "INVALID_REQUEST", state: "not_applied",
                          retry: "correct_request", detail: "HAR")
        #expect(!text(result).lowercased().contains("internal error"))
        #expect(!text(result).lowercased().contains("unconfirmed"))
        #expect(!FileManager.default.fileExists(atPath: fixture.vault.appendingPathComponent("notes/invalid.har").path))
        #expect(await fixture.versioning.calls == 0)
    }

    @Test("Canvas append explains the unsupported mode and the supported replacement")
    func unsupportedUpdateModeIsSpecific() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = "{\"nodes\":[],\"edges\":[]}"
        let created = try await fixture.controller.call(.init(name: "create_file", arguments: [
            "format": .string("canvas"), "path": .string("notes/map.canvas"), "content": .string(original),
        ]))
        try #require(created.isError != true)
        let revision = try #require(created.structuredContent?.objectValue?["revision"]?.stringValue)
        let result = try await fixture.controller.call(.init(name: "update_file", arguments: [
            "format": .string("canvas"), "path": .string("notes/map.canvas"), "content": .string(original),
            "mode": .string("append"), "expected_revision": .string(revision),
        ]))
        try expectFailure(result, code: "INVALID_REQUEST", state: "not_applied",
                          retry: "correct_request", detail: "append")
        #expect(text(result).contains("replace"))
        #expect(!text(result).contains("Operation 'update' is not supported"))
        #expect(try String(contentsOf: fixture.vault.appendingPathComponent("notes/map.canvas"), encoding: .utf8) == original)
        #expect(await fixture.versioning.calls == 1)
        let valid = try await fixture.controller.call(.init(name: "update_file", arguments: [
            "format": .string("canvas"), "path": .string("notes/map.canvas"), "content": .string(original),
            "mode": .string("replace"), "expected_revision": .string(revision),
        ]))
        #expect(valid.isError != true)
    }

    @Test("Repeated path separators are invalid syntax, not alleged symlinks")
    func repeatedSeparatorHasPreciseDiagnosis() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.controller.call(.init(name: "create_file", arguments: [
            "format": .string("json"), "path": .string("notes//invalid.json"), "content": .string("{}"),
        ]))
        try expectFailure(result, code: "INVALID_PATH", state: "not_applied",
                          retry: "correct_request", detail: "empty path component")
        #expect(!text(result).lowercased().contains("symbolic"))
        #expect(!FileManager.default.fileExists(atPath: fixture.vault.appendingPathComponent("notes/invalid.json").path))
        #expect(await fixture.versioning.calls == 0)
    }


    @Test("A stale file move is rejected before persistence without uncertainty")
    func staleMoveIsNotApplied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.create()
        let result = try await PathMoveToolController(readOnly: false, paths: fixture.paths).call(.init(
            name: "move_path", arguments: [
                "kind": .string("file"), "format": .string("json"),
                "source_path": .string("notes/source.json"), "destination_path": .string("notes/moved.json"),
                "expected_revision": .string("sha256:" + String(repeating: "0", count: 64)),
            ]
        ))
        try expectFailure(result, code: "REVISION_CONFLICT", state: "not_applied",
                          retry: "correct_request", detail: "changed")
        #expect(try Data(contentsOf: fixture.file) == Data("{}".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.vault.appendingPathComponent("notes/moved.json").path))
        #expect(await fixture.versioning.calls == 1)
    }

    @Test("A directory collision is rejected before persistence without uncertainty")
    func directoryCollisionIsNotApplied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for name in ["source", "destination"] {
            try FileManager.default.createDirectory(at: fixture.vault.appendingPathComponent("notes/" + name),
                                                    withIntermediateDirectories: true)
        }
        let result = try await PathMoveToolController(readOnly: false, paths: fixture.paths).call(.init(
            name: "move_path", arguments: [
                "kind": .string("directory"), "source_path": .string("notes/source"),
                "destination_path": .string("notes/destination"),
            ]
        ))
        try expectFailure(result, code: "OPERATION_FAILED", state: "not_applied",
                          retry: "correct_request", detail: "exists")
        #expect(FileManager.default.fileExists(atPath: fixture.vault.appendingPathComponent("notes/source").path))
        #expect(await fixture.versioning.calls == 0)
    }

    @Test("Move snapshot failures stay uncertain after bytes actually moved", arguments: [false, true])
    func persistedMoveFailureIsUnknown(_ directory: Bool) async throws {
        let failure = PathValidationError.pathContainsTraversal("PRIVATE_ERROR_MARKER")
        let fixture = try Fixture(snapshotFailure: failure)
        defer { fixture.cleanup() }
        let source = directory ? "notes/source/file.json" : "notes/source.json"
        let destination = directory ? "notes/destination/file.json" : "notes/destination.json"
        let url = fixture.vault.appendingPathComponent(source)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{}".utf8)
        try bytes.write(to: url)
        var args: [String: Value] = [
            "kind": .string(directory ? "directory" : "file"),
            "source_path": .string(directory ? "notes/source" : source),
            "destination_path": .string(directory ? "notes/destination" : destination),
        ]
        if !directory {
            args["format"] = .string("json")
            args["expected_revision"] = .string(FileSnapshot(data: bytes, modifiedDate: nil).revision.rawValue)
        }
        let result = try await PathMoveToolController(readOnly: false, paths: fixture.paths)
            .call(.init(name: "move_path", arguments: args))
        try expectFailure(result, code: "INVALID_PATH", state: "unknown",
                          retry: "inspect_state", detail: "inspect")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: fixture.vault.appendingPathComponent(destination)) == bytes)
        #expect(await fixture.versioning.calls == 1)
    }

    private func expectMissingReadAndDelete(_ fixture: Fixture, revision: String) async throws {
        try expectFailure(try await fixture.call("read_file"), code: "NOT_FOUND", state: "read_only",
                          retry: "correct_request", detail: "not found")
        try expectFailure(try await fixture.call("delete_file", revision: revision),
                          code: "NOT_FOUND", state: "not_applied", retry: "correct_request", detail: "not found")
    }

    private func expectFailure(_ result: CallTool.Result, code: String, state: String,
                               retry: String, detail: String) throws {
        #expect(result.isError == true)
        let message = text(result)
        #expect(message.lowercased().contains(detail.lowercased()))
        #expect(!message.contains("PRIVATE_ERROR_MARKER"))
        #expect(!message.contains("/private/"))
        #expect(message.utf8.count <= 1_024)
        let metadata = try #require(result.structuredContent?.objectValue?["error"]?.objectValue)
        #expect(metadata["code"]?.stringValue == code)
        #expect(metadata["state"]?.stringValue == state)
        #expect(metadata["retry"]?.stringValue == retry)
        #expect(Set(metadata.keys) == ["code", "state", "retry"])
        if state == "unknown" { #expect(message.lowercased().contains("inspect")) }
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    private struct Fixture {
        let parent: URL
        let vault: URL
        let controller: FileToolController
        let listing: VaultFileListingService
        let paths: VaultPathMoveService
        let versioning: SnapshotRecorder
        var file: URL { vault.appendingPathComponent("notes/source.json") }

        init(snapshotFailure: (any Error)? = nil) throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineErrors-\(UUID().uuidString)")
            vault = parent.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: vault.appendingPathComponent("notes"),
                                                    withIntermediateDirectories: true)
            let access = VaultAccessCoordinator(lockURL: parent.appendingPathComponent("vault.lock"))
            let dataDirectory = try VaultDataDirectory.prepare(
                vaultPath: vault.path,
                supportRoot: parent.appendingPathComponent("support", isDirectory: true)
            )
            versioning = SnapshotRecorder(
                repository: try GitRepository(
                    vaultURL: vault,
                    dataDirectory: dataDirectory
                ),
                failure: snapshotFailure
            )
            let sources = ExternalFileSourceValidator(vaultPath: vault.path)
            let catalog = FileFormatCatalogFactory.build(
                imageReader: ImageReader(encoder: CoreGraphicsImageEncoder(), limits: .default),
                imageImporter: ImageImporter(sourceValidator: sources, encoder: CoreGraphicsImageEncoder()),
                videoImporter: VideoImporter(sourceValidator: sources, encoder: AVFoundationVideoEncoder()),
                pdfReader: PDFReader()
            )
            controller = FileToolController(readOnly: false, files: VaultFileService(
                vaultPath: vault.path, catalog: catalog, store: VaultCRUDStore(vaultPath: vault.path),
                mutations: VaultMutationExecutor(versioning: versioning), access: access
            ))
            listing = VaultFileListingService(vaultPath: vault.path, capabilities: catalog.capabilities(), access: access)
            paths = VaultPathMoveService(vaultPath: vault.path, supportedFileFormats: [.json],
                                         versioning: versioning, access: access, readOnly: false)
        }

        func create() async throws -> CallTool.Result {
            try await controller.call(.init(name: "create_file", arguments: [
                "format": .string("json"), "path": .string("notes/source.json"), "content": .string("{}"),
            ]))
        }

        func call(_ name: String, revision: String? = nil) async throws -> CallTool.Result {
            var arguments: [String: Value] = ["format": .string("json"), "path": .string("notes/source.json")]
            if let revision { arguments["expected_revision"] = .string(revision) }
            return try await controller.call(.init(name: name, arguments: arguments))
        }

        func cleanup() { try? FileManager.default.removeItem(at: parent) }
    }

    private actor SnapshotRecorder: VaultVersioning {
        let repository: GitRepository
        let failure: (any Error)?
        private(set) var calls = 0
        init(repository: GitRepository, failure: (any Error)?) {
            self.repository = repository
            self.failure = failure
        }
        func recordSnapshot() async throws {
            calls += 1
            if let failure { throw failure }
            try await repository.recordSnapshot()
        }
    }
}
