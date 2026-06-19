import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import SecondBrainMCP

@Suite("ImageImporter")
struct ImageImporterTests {

    // MARK: - Helpers

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "ImageImporter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return root
    }

    /// A unique path OUTSIDE the vault, to stand in for an arbitrary source file.
    private func srcPath(_ name: String) -> String {
        NSTemporaryDirectory() + "imgimport-src-\(UUID().uuidString)-\(name)"
    }

    private func makeImage(width: Int, height: Int, red: CGFloat = 1) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func makePNG(width: Int, height: Int) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeImage(width: width, height: height), nil)
        _ = CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func makeJPEG(width: Int, height: Int) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makeImage(width: width, height: height), nil)
        _ = CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func bytesContain(_ haystack: Data, _ needle: String) -> Bool {
        let hay = [UInt8](haystack), pin = [UInt8](needle.utf8)
        guard pin.count <= hay.count else { return false }
        for i in 0...(hay.count - pin.count) where Array(hay[i..<i + pin.count]) == pin {
            return true
        }
        return false
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: - Happy paths

    @Test("Imports a real PNG (copy), source left intact")
    func importPNGCopy() async throws {
        let root = try makeVault()
        let src = srcPath("shot.png")
        try makePNG(width: 120, height: 80).write(to: URL(fileURLWithPath: src))

        let r = try await ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())
            .add(source: src, destination: "notes/assets/img.png", deleteSource: false)

        #expect(r.destination == "notes/assets/img.png")
        #expect(r.width == 120 && r.height == 80)
        #expect(r.sourceDeleted == false)
        #expect(exists(src))                                       // copy: source intact
        #expect(exists(root + "/notes/assets/img.png"))            // stored
        #expect(Array((try Data(contentsOf: URL(fileURLWithPath: root + "/notes/assets/img.png"))).prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test("Imports a JPEG, re-encodes to PNG, and deletes the source when asked")
    func importJPEGMove() async throws {
        let root = try makeVault()
        let src = srcPath("photo.jpg")
        try makeJPEG(width: 64, height: 64).write(to: URL(fileURLWithPath: src))

        let r = try await ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())
            .add(source: src, destination: "notes/a/photo.png", deleteSource: true)

        #expect(r.sourceFormat == "jpeg")                          // detected source format
        #expect(r.sourceDeleted == true)
        #expect(!exists(src))                                      // move: source gone
        #expect(exists(root + "/notes/a/photo.png"))
    }

    @Test("Destination extension is normalized to .png")
    func normalizesExtension() async throws {
        let root = try makeVault()
        let src = srcPath("x.png")
        try makePNG(width: 10, height: 10).write(to: URL(fileURLWithPath: src))

        let r = try await ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())
            .add(source: src, destination: "notes/a/shot.jpg", deleteSource: false)
        #expect(r.destination == "notes/a/shot.png")
        #expect(exists(root + "/notes/a/shot.png"))
    }

    // MARK: - Safety

    @Test("Re-encoding strips an appended payload — no hidden data survives")
    func stripsAppendedPayload() async throws {
        let root = try makeVault()
        let src = srcPath("polyglot.png")
        var bytes = makePNG(width: 64, height: 48)
        bytes.append(Data("HIDDEN_PAYLOAD_abcdef".utf8))           // valid PNG + trailing junk
        try bytes.write(to: URL(fileURLWithPath: src))

        let r = try await ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())
            .add(source: src, destination: "notes/assets/clean.png", deleteSource: false)

        let stored = try Data(contentsOf: URL(fileURLWithPath: root + "/" + r.destination))
        #expect(!bytesContain(stored, "HIDDEN_PAYLOAD"))           // payload gone
        #expect(Array(stored.prefix(4)) == [0x89, 0x50, 0x4E, 0x47]) // still a valid PNG
    }

    @Test("A non-image file with an image extension is rejected, nothing written")
    func rejectsFakeImage() async throws {
        let root = try makeVault()
        let src = srcPath("evil.png")
        try Data("#!/bin/sh\necho pwned\n".utf8).write(to: URL(fileURLWithPath: src))
        let importer = ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())

        await #expect(throws: ImageImporter.ImageImporterError.self) {
            try await importer.add(source: src, destination: "notes/x.png", deleteSource: false)
        }
        #expect(!exists(root + "/notes/x.png"))
    }

    @Test("Destination outside notes/ is rejected")
    func rejectsOutsideNotes() async throws {
        let root = try makeVault()
        let src = srcPath("ok.png")
        try makePNG(width: 10, height: 10).write(to: URL(fileURLWithPath: src))
        let importer = ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())

        await #expect(throws: ImageImporter.ImageImporterError.self) {
            try await importer.add(source: src, destination: "references/x.png", deleteSource: false)
        }
    }

    @Test("Existing destination is not clobbered")
    func rejectsExisting() async throws {
        let root = try makeVault()
        try FileManager.default.createDirectory(atPath: root + "/notes/a", withIntermediateDirectories: true)
        try Data([0]).write(to: URL(fileURLWithPath: root + "/notes/a/taken.png"))
        let src = srcPath("ok.png")
        try makePNG(width: 10, height: 10).write(to: URL(fileURLWithPath: src))
        let importer = ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())

        await #expect(throws: ImageImporter.ImageImporterError.self) {
            try await importer.add(source: src, destination: "notes/a/taken.png", deleteSource: false)
        }
    }

    @Test("Missing source is rejected")
    func rejectsMissingSource() async throws {
        let root = try makeVault()
        let importer = ImageImporter(vaultPath: root, encoder: CoreGraphicsImageEncoder())
        await #expect(throws: ImageImporter.ImageImporterError.self) {
            try await importer.add(source: srcPath("nope.png"), destination: "notes/x.png", deleteSource: false)
        }
    }
}
