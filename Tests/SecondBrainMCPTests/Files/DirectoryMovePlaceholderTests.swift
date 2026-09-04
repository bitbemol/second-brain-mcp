import Darwin
import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("Directory moves preserve supported dot-file placeholders", .serialized)
struct DirectoryMovePlaceholderTests {
    @Test("A snapshotted supported dot-file moves with its container and exact bytes",
          arguments: [".gitkeep.md", ".metadata.json"])
    func supportedDotFileMoves(_ name: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let bytes = name.hasSuffix(".md") ? Data() : Data("{}".utf8)
        let source = fixture.source.appendingPathComponent("attachments/" + name)
        try bytes.write(to: source)
        try await fixture.versioning.recordSnapshot()
        let before = FileSnapshot(data: try Data(contentsOf: source), modifiedDate: nil).revision

        let result = try await fixture.move()
        try #require(result.isError != true)
        #expect(result.structuredContent?.objectValue?["destination_path"]?.stringValue == "notes/completed/ticket")
        let destination = fixture.destination.appendingPathComponent("attachments/" + name)
        let after = try Data(contentsOf: destination)
        #expect(after == bytes)
        #expect(FileSnapshot(data: after, modifiedDate: nil).revision == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(await fixture.versioning.completedSnapshots == 2)
    }

    @Test("Dot-file support does not admit hidden directories, links, packages or unregistered dot-files",
          arguments: ["hidden-directory", "flagged-directory", "flagged-file", "symlink",
                      "package", ".gitkeep", ".env", ".DS_Store"])
    func unsafeDescendantsRemainRejected(_ kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.versioning.recordSnapshot()
        let attachments = fixture.source.appendingPathComponent("attachments")
        let protected = fixture.root.appendingPathComponent("outside.md")
        try Data("outside unchanged".utf8).write(to: protected)
        var flagToClear: URL?
        switch kind {
        case "hidden-directory":
            let directory = attachments.appendingPathComponent(".private")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data().write(to: directory.appendingPathComponent(".gitkeep.md"))
        case "flagged-directory", "package":
            let directory = attachments.appendingPathComponent(kind == "package" ? "Private.app" : "private")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            if kind == "flagged-directory" {
                try #require(Darwin.chflags(directory.path, UInt32(UF_HIDDEN)) == 0)
                flagToClear = directory
            }
        case "flagged-file":
            let file = attachments.appendingPathComponent(".gitkeep.md")
            try Data().write(to: file)
            try #require(Darwin.chflags(file.path, UInt32(UF_HIDDEN)) == 0)
            flagToClear = file
        case "symlink":
            try FileManager.default.createSymbolicLink(
                at: attachments.appendingPathComponent(".gitkeep.md"), withDestinationURL: protected
            )
        default:
            try Data("safe but unsupported placeholder".utf8)
                .write(to: attachments.appendingPathComponent(kind))
        }
        defer { if let flagToClear { _ = Darwin.chflags(flagToClear.path, 0) } }
        let result = try await fixture.move()
        #expect(result.isError == true)
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try Data(contentsOf: protected) == Data("outside unchanged".utf8))
        #expect(await fixture.versioning.completedSnapshots == 1)
    }

    @Test("Supported hidden text still reaches the credential and strict UTF-8 policies",
          arguments: ["credential", "invalid-utf8", "har-credential"])
    func dotFileSecurityPolicyIsNotBypassed(_ kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.versioning.recordSnapshot()
        let name = kind == "har-credential" ? ".capture.har" : ".gitkeep.md"
        let bytes: Data
        switch kind {
        case "credential":
            bytes = Data(("Bearer " + String(repeating: "s", count: 32)).utf8)
        case "invalid-utf8":
            bytes = Data([0xff])
        default:
            bytes = Data(#"{"log":{"entries":[{"request":{"headers":[{"name":"Authorization","value":"short-secret"}]}}]}}"#.utf8)
        }
        let file = fixture.source.appendingPathComponent("attachments/" + name)
        try bytes.write(to: file)
        do {
            _ = try await fixture.service.move(.directory(
                sourcePath: "notes/ticket", destinationPath: "notes/completed/ticket"
            ))
            Issue.record("Expected persisted-file policy rejection")
        } catch MutationFailure.beforePersistence(let cause) {
            switch kind {
            case "credential": #expect(cause is SensitiveContentPolicy.Violation)
            case "invalid-utf8": #expect(cause is TextFileSupport.TextError)
            default: #expect(cause is PersistedFileSecurityPolicy.Violation)
            }
        } catch {
            Issue.record("Expected policy rejection before persistence; received \(type(of: error))")
        }
        let result = try await fixture.move()
        #expect(result.isError == true)
        let text = result.content.compactMap {
            if case .text(let value, _, _) = $0 { value } else { nil }
        }.joined()
        #expect(!text.contains(String(repeating: "s", count: 32)))
        #expect(!text.contains("short-secret"))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(await fixture.versioning.completedSnapshots == 1)
    }

    @Test("Supported dot-file bytes remain charged to the subtree budget")
    func dotFileCountsTowardByteBudget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data(repeating: 65, count: 64).write(
            to: fixture.source.appendingPathComponent("attachments/.gitkeep.md")
        )
        let target = try NotesDirectoryTarget.resolve(path: "notes/ticket", vaultPath: fixture.root.path)
        do {
            _ = try DirectoryMoveSecurityPreflight.validate(target, maximumSubtreeBytes: 32)
            Issue.record("Expected aggregate byte-budget rejection")
        } catch DirectoryMoveError.resourceLimit {
            // Resource rejection, not rejection based on a supported leaf's name.
        } catch {
            Issue.record("Wrong rejection category: \(type(of: error))")
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let service: VaultPathMoveService
        let versioning: RecordingVersioning

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectoryPlaceholder-\(UUID().uuidString)")
            source = root.appendingPathComponent("notes/ticket")
            destination = root.appendingPathComponent("notes/completed/ticket")
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent("attachments"), withIntermediateDirectories: true
            )
            try Data("# Ticket\n".utf8).write(to: source.appendingPathComponent("overview.md"))
            let dataDirectory = try VaultDataDirectory.prepare(
                vaultPath: root.path,
                supportRoot: root.appendingPathComponent(".test-support", isDirectory: true)
            )
            versioning = RecordingVersioning(
                repository: try GitRepository(
                    vaultURL: root,
                    dataDirectory: dataDirectory
                )
            )
            service = VaultPathMoveService(
                vaultPath: root.path, supportedFileFormats: [.markdown, .json, .har],
                versioning: versioning,
                access: VaultAccessCoordinator(lockURL: root.appendingPathComponent("test-vault.lock")),
                readOnly: false
            )
        }

        func move() async throws -> CallTool.Result {
            try await PathMoveToolController(readOnly: false, paths: service).call(.init(
                name: "move_path", arguments: [
                    "kind": .string("directory"), "source_path": .string("notes/ticket"),
                    "destination_path": .string("notes/completed/ticket"),
                ]
            ))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private actor RecordingVersioning: VaultVersioning {
        let repository: GitRepository
        private(set) var completedSnapshots = 0
        init(repository: GitRepository) { self.repository = repository }
        func prepareForMutation(changing paths: [String]?) async throws {
            try await repository.prepareForMutation(changing: paths)
        }
        func recordSnapshot() async throws {
            try await repository.recordSnapshot()
            completedSnapshots += 1
        }
    }
}
