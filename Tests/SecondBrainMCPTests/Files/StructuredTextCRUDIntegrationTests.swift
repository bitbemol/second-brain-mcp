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

            expectedRevision: updatedRevision,
            format: .csv,
            path: path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: context.root.appendingPathComponent(path).path
        ))
    }

    @Test
    func `Generic text editing preserves BOM and rejects invalid final content`() async throws {
        let context = try await makeContext()
        defer { context.cleanup() }
        let path = "notes/bom.json"
        let original = "\u{FEFF}{\"value\":1}"

        let created = try await context.service.create(CreateFileRequest(
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

        let updated = try await context.service.update(UpdateFileRequest(
            expectedRevision: createdRevision,
            format: .json,
            path: path,
            content: nil,
            mode: .patch,
            replacements: [
                TextReplacement(oldText: "1", newText: "2"),
            ]
        ))
        let updatedRevision = try #require(updated.metadata?.revision)
        let storedURL = context.root.appendingPathComponent(path)
        let validBytes = try Data(contentsOf: storedURL)
        #expect(validBytes.starts(with: [0xEF, 0xBB, 0xBF]))

        await expectPreparationFailure(JSONFileOperations.InvalidJSON.self) {
            _ = try await context.service.update(UpdateFileRequest(
                expectedRevision: updatedRevision,
                format: .json,
                path: path,
                content: nil,
                mode: .patch,
                replacements: [
                    TextReplacement(oldText: "2", newText: "}"),
                ]
            ))
        }
        #expect(try Data(contentsOf: storedURL) == validBytes)
    }

    @Test(arguments: [FileFormat.json, .csv, .patch])
    func rawTextDiscoveryDoesNotCertifyStoredFormatStructure(_ format: FileFormat) async throws {
        let context = try await makeContext()
        defer {
            removeSearchFixture(context.root)
            context.cleanup()
        }
        let text: String
        switch format {
        case .json: text = #"{"needle":}"#
        case .csv: text = "heading,other\nneedle"
        case .patch: text = "needle without a unified diff"
        default: throw OutputError.unexpectedFormat
        }
        let path = "notes/invalid.\(format.rawValue)"
        try Data(text.utf8).write(to: context.root.appendingPathComponent(path))
        let search = VaultSearchEngine(source: SearchCorpusBuilder(
            vaultPath: context.root.path,
            capabilities: context.capabilities,
            captureStore: searchCaptureFixture(context.root),
            access: context.access
        ))

        let found = try await search.search(VaultSearchRequest(location: .notes, query: "needle"))
        #expect(found.results.map(\.path) == [path])
        #expect(found.results.first?.format == format)
        #expect(found.coverage.complete)
        #expect(found.coverage.failedFiles == nil)

        do {
            _ = try await context.service.read(ReadFileRequest(
                format: format, path: path, options: .default
            ))
            Issue.record("Text discovery must not bypass strict format validation during read")
        } catch {
            switch format {
            case .json: #expect(error is JSONFileOperations.InvalidJSON)
            case .csv: #expect(error is CSVDocumentInspector.ValidationError)
            case .patch: #expect(error is PatchFileOperations.PatchError)
            default: throw OutputError.unexpectedFormat
            }
        }
        #expect(try Data(contentsOf: context.root.appendingPathComponent(path)) == Data(text.utf8))
    }

    private struct Context {
        let root: URL
        let processDataParent: URL
        let service: VaultFileService
        let capabilities: FileCapabilities
        let access: VaultAccessCoordinator

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
        let versioning = try GitRepository(repositoryURL: root)
        try await versioning.recordSnapshot()
        let store = VaultCRUDStore(vaultPath: root.path)
        let limits = ImageLimits.default
        let externalSources = ExternalFileSourceValidator(vaultPath: root.path)
        let catalog = FileFormatCatalogFactory.build(
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
        let access = VaultAccessCoordinator(
            lockURL: dataDirectory.lockDirectoryURL
                .appendingPathComponent("vault-access.lock")
        )
        let service = VaultFileService(
            vaultPath: root.path,
            catalog: catalog,
            store: store,
            mutations: VaultMutationExecutor(versioning: versioning),
            access: access
        )
        return Context(
            root: root,
            processDataParent: dataDirectory.rootURL.deletingLastPathComponent(),
            service: service,
            capabilities: catalog.capabilities(),
            access: access
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
        case unexpectedFormat
    }
}
