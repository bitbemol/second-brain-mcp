import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import SecondBrainMCP

// MARK: - Test helpers

/// A fake encoder so the policy (caps, pass-through, bomb guard) can be tested
/// without real image files or a real decoder.
private struct FakeImageEncoder: ImageEncoding {
    let inspection: ImageInspection
    let downscaled: Data

    init(width: Int, height: Int, format: String = "png", downscaled: Data = Data([9, 9, 9])) {
        self.inspection = ImageInspection(pixelWidth: width, pixelHeight: height, format: format)
        self.downscaled = downscaled
    }

    func inspect(url: URL) throws -> ImageInspection { inspection }
    func encodeDownscaledPNG(url: URL, maxLongEdge: Int) throws -> Data { downscaled }
}

private func makeVault() throws -> String {
    let root = NSTemporaryDirectory() + "ImageManagerTests-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/notes/attachments", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: root + "/references", withIntermediateDirectories: true)
    return root
}

private func write(_ data: Data, to relativePath: String, in root: String) throws {
    try data.write(to: URL(fileURLWithPath: root + "/" + relativePath))
}

/// Build a real, solid-color PNG of the given pixel size.
private func makePNG(width: Int, height: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
    return data as Data
}

private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

// MARK: - Policy (fake encoder)

@Suite("ImageManager — policy")
struct ImageManagerPolicyTests {

    @Test("Within-cap image is passed through byte-identical")
    func passThrough() throws {
        let root = try makeVault()
        let bytes = Data("not really a png, but pass-through doesn't decode".utf8)
        try write(bytes, to: "notes/attachments/small.png", in: root)

        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 800, height: 600))
        let result = try reader.read(relativePath: "notes/attachments/small.png")

        #expect(result.wasResized == false)
        #expect(result.pngData == bytes)
        #expect(result.originalWidth == 800)
        #expect(result.originalHeight == 600)
    }

    @Test("Oversized image is downscaled via the encoder")
    func downscale() throws {
        let root = try makeVault()
        try write(Data([0, 1, 2]), to: "notes/attachments/wide.png", in: root)

        let sentinel = Data([7, 7, 7, 7])
        let reader = ImageManager(
            vaultPath: root,
            encoder: FakeImageEncoder(width: 5000, height: 1000, downscaled: sentinel)
        )
        let result = try reader.read(relativePath: "notes/attachments/wide.png")

        #expect(result.wasResized == true)
        #expect(result.pngData == sentinel)
        #expect(result.originalWidth == 5000)
    }

    @Test("Decode-bomb dimensions are rejected before decoding")
    func bombRejected() throws {
        let root = try makeVault()
        try write(Data([0]), to: "notes/attachments/bomb.png", in: root)

        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 100_000, height: 100_000))
        #expect(throws: ImageManager.ImageError.self) {
            try reader.read(relativePath: "notes/attachments/bomb.png")
        }
    }

    @Test("Oversized file is rejected before opening")
    func fileTooLarge() throws {
        let root = try makeVault()
        try write(Data(count: 1000), to: "notes/attachments/huge.png", in: root)

        let tightConfig = ImageManager.Config(maxLongEdge: 2576, maxFileBytes: 100, maxMegapixels: 50)
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 10, height: 10), config: tightConfig)
        #expect(throws: ImageManager.ImageError.self) {
            try reader.read(relativePath: "notes/attachments/huge.png")
        }
    }

    @Test("Non-PNG extension is rejected")
    func wrongExtension() throws {
        let root = try makeVault()
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 10, height: 10))
        #expect(throws: (any Error).self) {
            try reader.read(relativePath: "notes/attachments/photo.jpg")
        }
    }

    @Test("Path outside notes/ or references/ is rejected")
    func outsideAllowedRoots() throws {
        let root = try makeVault()
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 10, height: 10))
        #expect(throws: ImageManager.ImageError.self) {
            try reader.read(relativePath: "secrets/key.png")
        }
    }

    @Test("Missing file throws notFound")
    func missingFile() throws {
        let root = try makeVault()
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 10, height: 10))
        #expect(throws: ImageManager.ImageError.self) {
            try reader.read(relativePath: "notes/attachments/nope.png")
        }
    }
}

// MARK: - Real encoder + end-to-end

@Suite("CoreGraphicsImageEncoder")
struct CoreGraphicsImageEncoderTests {

    @Test("inspect reads dimensions and format without decoding")
    func inspect() throws {
        let root = try makeVault()
        try write(makePNG(width: 120, height: 80), to: "notes/attachments/real.png", in: root)

        let encoder = CoreGraphicsImageEncoder()
        let info = try encoder.inspect(url: URL(fileURLWithPath: root + "/notes/attachments/real.png"))
        #expect(info.pixelWidth == 120)
        #expect(info.pixelHeight == 80)
        #expect(info.format == "png")
    }

    @Test("encodeDownscaledPNG bounds the long edge and emits valid PNG")
    func downscale() throws {
        let root = try makeVault()
        try write(makePNG(width: 400, height: 200), to: "notes/attachments/big.png", in: root)

        let encoder = CoreGraphicsImageEncoder()
        let out = try encoder.encodeDownscaledPNG(
            url: URL(fileURLWithPath: root + "/notes/attachments/big.png"), maxLongEdge: 100
        )
        // PNG signature
        #expect(Array(out.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        let size = try #require(pixelSize(of: out))
        #expect(max(size.width, size.height) <= 100)
    }

    @Test("ImageManager passes a small real PNG through unchanged")
    func endToEndPassThrough() throws {
        let root = try makeVault()
        let png = makePNG(width: 300, height: 200)
        try write(png, to: "notes/attachments/screenshot.png", in: root)

        let reader = ImageManager(vaultPath: root, encoder: CoreGraphicsImageEncoder())
        let result = try reader.read(relativePath: "notes/attachments/screenshot.png")
        #expect(result.wasResized == false)
        #expect(result.pngData == png)
        #expect(result.originalWidth == 300)
    }

    @Test("ImageManager downscales a large real PNG to the cap")
    func endToEndDownscale() throws {
        let root = try makeVault()
        try write(makePNG(width: 4000, height: 100), to: "references/wide.png", in: root)

        let reader = ImageManager(vaultPath: root, encoder: CoreGraphicsImageEncoder())
        let result = try reader.read(relativePath: "references/wide.png")
        #expect(result.wasResized == true)
        let size = try #require(pixelSize(of: result.pngData))
        #expect(max(size.width, size.height) <= 2576)
    }
}
