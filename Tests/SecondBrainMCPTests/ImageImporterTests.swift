import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SecondBrainMCP

@Suite("ImageImporter preparation")
struct ImageImporterTests {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "ImageImporter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return root
    }

    private func sourcePath(_ name: String) -> String {
        NSTemporaryDirectory() + "image-source-\(UUID().uuidString)-\(name)"
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeImageData(width: Int, height: Int, type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, makeImage(width: width, height: height), nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func contains(_ data: Data, text: String) -> Bool {
        let bytes = [UInt8](data)
        let target = [UInt8](text.utf8)
        guard target.count <= bytes.count else { return false }
        return (0...(bytes.count - target.count)).contains { index in
            Array(bytes[index..<(index + target.count)]) == target
        }
    }

    @Test("Prepares a real PNG without touching its source")
    func preparesPNG() async throws {
        let root = try makeVault()
        let source = sourcePath("image.png")
        try makeImageData(width: 120, height: 80, type: .png)
            .write(to: URL(fileURLWithPath: source))

        let prepared = try await ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: CoreGraphicsImageEncoder()
        ).prepare(source: source)

        #expect(prepared.width == 120)
        #expect(prepared.height == 80)
        #expect(Array(prepared.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(FileManager.default.fileExists(atPath: source))
    }

    @Test("Re-encodes JPEG input as clean PNG data")
    func preparesJPEG() async throws {
        let root = try makeVault()
        let source = sourcePath("image.jpg")
        try makeImageData(width: 64, height: 64, type: .jpeg)
            .write(to: URL(fileURLWithPath: source))

        let prepared = try await ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: CoreGraphicsImageEncoder()
        ).prepare(source: source)

        #expect(prepared.sourceFormat == .jpeg)
        #expect(Array(prepared.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test("Resizes oversized input during preparation")
    func resizesOversizedImage() async throws {
        let root = try makeVault()
        let source = sourcePath("large.png")
        try makeImageData(width: 400, height: 200, type: .png)
            .write(to: URL(fileURLWithPath: source))
        let limits = ImageLimits(
            maxLongEdge: 100,
            maxFileBytes: FileFormat.png.maximumFileBytes,
            maxMegapixels: 50,
            gifMaxFrames: 8,
            gifMaxSourceFrames: 10_000,
            gifFrameMaxLongEdge: 100
        )
        let encoder = CoreGraphicsImageEncoder()

        let prepared = try await ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: encoder,
            limits: limits
        ).prepare(source: source)
        let temporary = URL(fileURLWithPath: sourcePath("prepared.png"))
        try prepared.data.write(to: temporary)
        let inspection = try encoder.inspect(url: temporary)

        #expect(inspection.pixelWidth == 100)
        #expect(inspection.pixelHeight == 50)
        #expect(prepared.note?.contains("resized long edge") == true)
    }

    @Test("Re-encoding strips appended payloads")
    func stripsPayload() async throws {
        let root = try makeVault()
        let source = sourcePath("polyglot.png")
        var data = makeImageData(width: 64, height: 48, type: .png)
        data.append(Data("HIDDEN_PAYLOAD".utf8))
        try data.write(to: URL(fileURLWithPath: source))

        let prepared = try await ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: CoreGraphicsImageEncoder()
        ).prepare(source: source)

        #expect(!contains(prepared.data, text: "HIDDEN_PAYLOAD"))
    }

    @Test("Rejects non-images")
    func rejectsNonImage() async throws {
        let root = try makeVault()
        let source = sourcePath("fake.png")
        try Data("#!/bin/sh".utf8).write(to: URL(fileURLWithPath: source))
        let importer = ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: CoreGraphicsImageEncoder()
        )

        await #expect(throws: ImageImportError.self) {
            try await importer.prepare(source: source)
        }
    }

    @Test("Rejects missing and non-regular sources")
    func rejectsInvalidSources() async throws {
        let root = try makeVault()
        let importer = ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: CoreGraphicsImageEncoder()
        )
        await #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try await importer.prepare(source: sourcePath("missing.png"))
        }

        let directory = sourcePath("directory")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        await #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try await importer.prepare(source: directory)
        }
    }

    @Test("Applies size checks to a symlink target")
    func checksSymlinkTargetSize() async throws {
        let root = try makeVault()
        let target = sourcePath("large.bin")
        try Data(count: 2_000).write(to: URL(fileURLWithPath: target))
        let link = sourcePath("link.png")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let limits = ImageLimits(
            maxLongEdge: 2_576,
            maxFileBytes: 1_000,
            maxMegapixels: 50,
            gifMaxFrames: 8,
            gifMaxSourceFrames: 10_000,
            gifFrameMaxLongEdge: 1_280
        )
        let importer = ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: CoreGraphicsImageEncoder(),
            limits: limits
        )

        do {
            _ = try await importer.prepare(source: link)
            Issue.record("Expected sourceTooLarge")
        } catch let error as ExternalFileSourceValidator.ValidationError {
            guard case .sourceTooLarge = error else {
                Issue.record("Expected sourceTooLarge, got \(error)")
                return
            }
        }
    }

    @Test("Follows image symlinks but rejects sources inside the vault")
    func enforcesSourceBoundary() async throws {
        let root = try makeVault()
        let external = sourcePath("external.png")
        try makeImageData(width: 30, height: 30, type: .png)
            .write(to: URL(fileURLWithPath: external))
        let link = sourcePath("alias.png")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: external)
        let importer = ImageImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: CoreGraphicsImageEncoder()
        )

        let prepared = try await importer.prepare(source: link)
        #expect(prepared.width == 30)

        let internalSource = root + "/notes/existing.png"
        try makeImageData(width: 20, height: 20, type: .png)
            .write(to: URL(fileURLWithPath: internalSource))
        await #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try await importer.prepare(source: internalSource)
        }
    }
}
