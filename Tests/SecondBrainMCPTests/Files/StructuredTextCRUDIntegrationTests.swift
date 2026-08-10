import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Structured text routed CRUD` {
    @Test
    func `JSON completes create, read, update, and soft delete`() async throws {
        let context = try await makeContext()
        defer { context.cleanup() }
        let path = "notes/fixture.json"
        let original = "{\n  \"enabled\": false,\n  \"count\": 1\n}\n"

        let created = try await context.service.create(CreateFileRequest(
            mutationID: MutationID(),
            format: .json,
            path: path,
            content: original,
            source: nil,
            tags: [],
            transform: nil
        ))
        let createdRevision = try #require(created.metadata?.revision)

        let read = try await context.service.read(ReadFileRequest(
            format: .json,
            path: path,
            options: .default
        ))
        #expect(try outputText(read) == original)
        #expect(read.metadata?.revision == createdRevision)

        let updated = try await context.service.update(UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: createdRevision,
            format: .json,
            path: path,
            content: nil,
            mode: .patch,
            replacements: [
                TextReplacement(oldText: "false", newText: "true"),
            ]
        ))
        let updatedRevision = try #require(updated.metadata?.revision)
        #expect(updatedRevision != createdRevision)
        #expect(try String(
            contentsOf: context.root.appendingPathComponent(path),
            encoding: .utf8
        ).contains("\"enabled\": true"))

        _ = try await context.service.delete(DeleteFileRequest(
            mutationID: MutationID(),
            expectedRevision: updatedRevision,
            format: .json,
            path: path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent(path).path
        ))
    }

    @Test
    func `CSV completes create, read, update, and soft delete`() async throws {
        let context = try await makeContext()
        defer { context.cleanup() }
        let path = "notes/results.csv"
        let original = "id,result\n1,pass"

        let created = try await context.service.create(CreateFileRequest(
            mutationID: MutationID(),
            format: .csv,
            path: path,
            content: original,
            source: nil,
            tags: [],
            transform: nil
        ))
        let createdRevision = try #require(created.metadata?.revision)

        let read = try await context.service.read(ReadFileRequest(
            format: .csv,
            path: path,
            options: .default
        ))
        #expect(try outputText(read) == original)
        #expect(read.metadata?.revision == createdRevision)

        let updated = try await context.service.update(UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: createdRevision,
            format: .csv,
            path: path,
            content: "2,fail",
            mode: .append,
            replacements: []
        ))
        let updatedRevision = try #require(updated.metadata?.revision)
        #expect(updatedRevision != createdRevision)
        #expect(try String(
            contentsOf: context.root.appendingPathComponent(path),
            encoding: .utf8
        ) == "id,result\n1,pass\n2,fail")

        _ = try await context.service.delete(DeleteFileRequest(
            mutationID: MutationID(),
            expectedRevision: updatedRevision,
            format: .csv,
            path: path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent(path).path
        ))
    }

    private struct Context {
        let root: URL
        let processDataParent: URL
        let service: VaultFileService

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: processDataParent)
        }
    }

    private func makeContext() async throws -> Context {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "StructuredTextCRUDIntegrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references", isDirectory: true),
            withIntermediateDirectories: true
        )

        let dataDirectory = try makeTestDataDirectory(vaultPath: root.path)
        let versioning = try GitRepository(
            repositoryURL: root,
            lockURL: dataDirectory.lockDirectoryURL
                .appendingPathComponent("vault-versioning.lock")
        )
        try await versioning.recordSnapshot()
        let audit = AuditLogger(dataDirectory: dataDirectory)
        let store = VaultCRUDStore(vaultPath: root.path)
        let limits = ImageLimits.default
        let externalSources = ExternalFileSourceValidator(vaultPath: root.path)
        let catalog = FileFormatCatalogFactory.build(
            vaultPath: root.path,
            store: store,
            imageReader: ImageReader(
                encoder: CoreGraphicsImageEncoder(),
                limits: limits
            ),
            imageImporter: ImageImporter(
                sourceValidator: externalSources,
                encoder: CoreGraphicsImageEncoder(),
                limits: limits
            ),
            videoImporter: VideoImporter(
                sourceValidator: externalSources,
                encoder: AVFoundationVideoEncoder()
            ),
            pdfReader: PDFReader()
        )
        let service = VaultFileService(
            vaultPath: root.path,
            catalog: catalog,
            store: store,
            mutations: VaultMutationExecutor(
                versioning: versioning,
                audit: audit,
                receipts: MutationReceiptStore(dataDirectory: dataDirectory)
            ),
            operations: VaultOperationCoordinator(
                lockDirectoryURL: dataDirectory.lockDirectoryURL
            ),
            audit: audit
        )
        return Context(
            root: root,
            processDataParent: dataDirectory.rootURL.deletingLastPathComponent(),
            service: service
        )
    }

    private func outputText(_ output: FileOperationOutput) throws -> String {
        guard case .text(let text) = output.contents.first else {
            throw OutputError.missingText
        }
        return text
    }

    private enum OutputError: Error {
        case missingText
    }
}
