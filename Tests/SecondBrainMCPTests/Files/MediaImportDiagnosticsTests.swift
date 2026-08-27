import Foundation
import CoreGraphics
import ImageIO
import MCP
import Testing
import UniformTypeIdentifiers
@testable import second_brain_mcp

@Suite("Media import boundary diagnostics")
struct MediaImportDiagnosticsTests {
    @Test("External-source policy failures remain actionable without exposing source paths",
          arguments: ["inside", "missing", "directory", "oversize"])
    func sourcePolicyFailuresAreActionable(_ kind: String) async throws {
        let fixture = try MediaImportBoundaryFixture(maximumImageBytes: 64)
        defer { fixture.cleanup() }
        let source: URL
        let expected: String
        switch kind {
        case "inside":
            source = fixture.vault.appendingPathComponent("notes/PRIVATE_MEDIA_SOURCE.png")
            try Data(repeating: 1, count: 16).write(to: source)
            expected = "outside the vault"
        case "missing":
            source = fixture.parent.appendingPathComponent("PRIVATE_MEDIA_SOURCE-missing.png")
            expected = "not found"
        case "directory":
            source = fixture.parent.appendingPathComponent("PRIVATE_MEDIA_SOURCE-directory")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            expected = "regular file"
        default:
            source = fixture.parent.appendingPathComponent("PRIVATE_MEDIA_SOURCE-large.png")
            try Data(repeating: 1, count: 65).write(to: source)
            expected = "limit 64"
        }
        let result = try await fixture.create(source: source, format: .png)
        expectActionable(result, containing: expected, forbidden: source.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination(.png).path))
        #expect(await fixture.versioning.snapshots == 0)
        if kind == "inside" { #expect(try Data(contentsOf: source).count == 16) }
    }

    @Test("Malformed image and video files identify the media problem before persistence",
          arguments: [FileFormat.png, .gif])
    func invalidMediaIsActionable(_ format: FileFormat) async throws {
        let fixture = try MediaImportBoundaryFixture()
        defer { fixture.cleanup() }
        let source = fixture.parent.appendingPathComponent(
            "PRIVATE_MEDIA_SOURCE." + (format == .png ? "png" : "mov")
        )
        let original = Data("this is not a media container".utf8)
        try original.write(to: source)
        let result = try await fixture.create(source: source, format: format)
        expectActionable(result, containing: format == .png ? "image" : "video", forbidden: source.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination(format).path))
        #expect(try Data(contentsOf: source) == original)
        #expect(await fixture.versioning.snapshots == 0)
    }

    @Test("Audited media failures omit arbitrary details but retain corrective policy")
    func auditedMediaErrorsNeverEchoDetails() async throws {
        let privateDetail = "/private/PRIVATE_MEDIA_SOURCE/" + String(repeating: "x", count: 8_192)
        let failures: [(any Error, String)] = [
            (ImageImportError.notAnImage(privateDetail), "image"),
            (ImageImportError.unsupportedFormat(privateDetail), "format"),
            (ImageFileOperations.ImageOperationError.sourceRequired, "external"),
            (ImageFileOperations.ImageOperationError.transformRequired, "video_to_gif"),
            (VideoImportError.notAVideo(privateDetail), "video"),
            (VideoImportError.durationTooLong(seconds: 2, limit: 1), "limit 1"),
            (VideoImportError.outputTooLarge(bytes: 65, limit: 64), "limit 64"),
            (VideoImportError.conversionFailed(privateDetail), "conversion"),
            (ImageResourcePolicy.ValidationError.invalidDimensions(width: 0, height: 2), "dimensions"),
            (ImageResourcePolicy.ValidationError.tooManyPixels(megapixels: 51, limit: 50), "limit 50"),
            (ImageResourcePolicy.ValidationError.invalidFrameCount(0), "frame"),
            (ImageResourcePolicy.ValidationError.tooManyAnimationFrames(count: 11, limit: 10), "limit 10"),
        ]
        for (error, expected) in failures {
            let result = try await FileToolController(
                readOnly: false, files: FailingMediaService(error: error)
            ).call(.init(name: "create_file", arguments: [
                "format": .string("png"), "path": .string("notes/import.png"),
                "source": .string("/tmp/external.png"),
            ]))
            expectActionable(result, containing: expected, forbidden: privateDetail)
        }
    }

    @Test("Known image frame ceilings are not disguised as unreadable images")
    func frameLimitRemainsActionableThroughImporter() async throws {
        let fixture = try MediaImportBoundaryFixture(imageEncoder: ThrowingImageEncoder(
            error: CoreGraphicsImageEncoder.EncoderError.tooManyFrames(count: 11, limit: 10),
            duringInspection: true
        ))
        defer { fixture.cleanup() }
        let source = fixture.parent.appendingPathComponent("PRIVATE_MEDIA_SOURCE.gif")
        try Data(repeating: 1, count: 16).write(to: source)
        let result = try await fixture.create(source: source, format: .png)
        expectActionable(result, containing: "limit 10", forbidden: source.path)
        #expect(await fixture.versioning.snapshots == 0)
    }

    @Test("Unknown image and video failures stay opaque at both encoder phases",
          arguments: [true, false])
    func unknownEncoderErrorsRemainOpaque(_ duringInspection: Bool) async throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                            userInfo: [NSLocalizedDescriptionKey: "/private/PRIVATE_MEDIA_SOURCE"])
        for format in [FileFormat.png, .gif] {
            let fixture = try MediaImportBoundaryFixture(
                imageEncoder: ThrowingImageEncoder(error: error, duringInspection: duringInspection),
                videoEncoder: ThrowingVideoEncoder(error: error, duringInspection: duringInspection)
            )
            defer { fixture.cleanup() }
            let source = fixture.parent.appendingPathComponent("PRIVATE_MEDIA_SOURCE.bin")
            try Data(repeating: 1, count: 16).write(to: source)
            let result = try await fixture.create(source: source, format: format)
            #expect(result.isError == true)
            #expect(mediaResultText(result) == "File operation failed due to an internal error")
            #expect(!mediaResultText(result).contains("PRIVATE_MEDIA_SOURCE"))
            #expect(!FileManager.default.fileExists(atPath: fixture.destination(format).path))
            #expect(await fixture.versioning.snapshots == 0)
        }
    }

    @Test("A generated external PNG crosses the real tool, storage, and Git boundaries")
    func validPNGImportSucceeds() async throws {
        let fixture = try MediaImportBoundaryFixture()
        defer { fixture.cleanup() }
        let source = fixture.parent.appendingPathComponent("external.png")
        let context = try #require(CGContext(
            data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: source)
        let result = try await fixture.create(source: source, format: .png)
        let stored = try await fixture.expectSuccessfulImport(result, source: source, format: .png)
        #expect(try Data(contentsOf: source) == data as Data)
        let decoded = try #require(CGImageSourceCreateWithData(stored as CFData, nil))
        let outputImage = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(outputImage.width == 16)
        #expect(outputImage.height == 12)
    }

    private func expectActionable(_ result: CallTool.Result, containing detail: String, forbidden: String) {
        let message = mediaResultText(result)
        #expect(result.isError == true)
        #expect(message.contains(detail))
        #expect(!message.contains("internal error"))
        #expect(!message.contains("PRIVATE_MEDIA_SOURCE"))
        #expect(!message.contains("/private/"))
        #expect(!message.contains(forbidden))
        #expect(message.utf8.count <= 1_024)
    }

    private struct FailingMediaService: FileCRUDService {
        let error: any Error
        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput { throw error }
        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput { throw error }
        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput { throw error }
        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput { throw error }
    }

    private struct ThrowingImageEncoder: ImageEncoding {
        let error: any Error
        let duringInspection: Bool
        func inspect(url: URL, maximumAnimationFrames: Int) throws -> ImageInspection {
            if duringInspection { throw error }
            return ImageInspection(pixelWidth: 1, pixelHeight: 1, format: "png",
                                   frameCount: 1, frameDelays: nil)
        }
        func encodeFramePNG(url: URL, frameIndex: Int, maxLongEdge: Int) throws -> Data { throw error }
    }

    private struct ThrowingVideoEncoder: VideoEncoding {
        let error: any Error
        let duringInspection: Bool
        func inspect(url: URL) async throws -> VideoInspection {
            if duringInspection { throw error }
            return VideoInspection(durationSeconds: 1, width: 1, height: 1, hasVideoTrack: true)
        }
        func makeGIF(url: URL, atTimes times: [Double], frameDelay: Double,
                     maxLongEdge: Int, maximumBytes: Int) async throws -> Data { throw error }
    }
}

/// Shared by the image and real-video boundary tests; every path is fixture-owned.
struct MediaImportBoundaryFixture {
    let parent: URL
    let vault: URL
    let service: VaultFileService
    let versioning: MediaImportVersioning

    init(maximumImageBytes: Int = 1_048_576,
         imageEncoder: any ImageEncoding = CoreGraphicsImageEncoder(),
         videoEncoder: any VideoEncoding = AVFoundationVideoEncoder()) throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImportBoundary-\(UUID().uuidString)")
        vault = parent.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("notes"),
                                                withIntermediateDirectories: true)
        versioning = MediaImportVersioning(repository: try GitRepository(repositoryURL: vault))
        let sources = ExternalFileSourceValidator(vaultPath: vault.path)
        let limits = ImageLimits(maxLongEdge: 128, maxFileBytes: maximumImageBytes,
                                 maxMegapixels: 50, gifMaxFrames: 8,
                                 gifMaxSourceFrames: 10_000, gifFrameMaxLongEdge: 128)
        let catalog = FileFormatCatalogFactory.build(
            imageReader: ImageReader(encoder: imageEncoder, limits: limits),
            imageImporter: ImageImporter(sourceValidator: sources, encoder: imageEncoder, limits: limits),
            videoImporter: VideoImporter(sourceValidator: sources, encoder: videoEncoder),
            pdfReader: PDFReader()
        )
        service = VaultFileService(
            vaultPath: vault.path, catalog: catalog, store: VaultCRUDStore(vaultPath: vault.path),
            mutations: VaultMutationExecutor(versioning: versioning),
            access: VaultAccessCoordinator(lockURL: parent.appendingPathComponent("vault.lock"))
        )
    }

    func create(source: URL, format: FileFormat) async throws -> CallTool.Result {
        var arguments: [String: Value] = [
            "format": .string(format.rawValue), "path": .string("notes/import." + format.rawValue),
            "source": .string(source.path),
        ]
        if format == .gif { arguments["transform"] = .string("video_to_gif") }
        return try await FileToolController(readOnly: false, files: service)
            .call(.init(name: "create_file", arguments: arguments))
    }

    func destination(_ format: FileFormat) -> URL {
        vault.appendingPathComponent("notes/import." + format.rawValue)
    }

    func expectSuccessfulImport(_ result: CallTool.Result, source: URL, format: FileFormat) async throws -> Data {
        #expect(result.isError != true)
        let stored = try Data(contentsOf: destination(format))
        let revision = FileSnapshot(data: stored, modifiedDate: nil).revision.rawValue
        #expect(mediaResultText(result).contains(revision))
        #expect(!mediaResultText(result).contains(source.path))
        #expect(await versioning.snapshots == 1)
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(".git/HEAD").path))
        return stored
    }

    func cleanup() { try? FileManager.default.removeItem(at: parent) }
}

actor MediaImportVersioning: VaultVersioning {
    let repository: GitRepository
    private(set) var snapshots = 0
    init(repository: GitRepository) { self.repository = repository }
    func recordSnapshot() async throws {
        try await repository.recordSnapshot()
        snapshots += 1
    }
}

private func mediaResultText(_ result: CallTool.Result) -> String {
    result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
}
