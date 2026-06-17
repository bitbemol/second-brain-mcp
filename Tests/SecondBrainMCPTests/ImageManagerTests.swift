import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import SecondBrainMCP

// MARK: - Test helpers

/// Fake encoder so the policy (caps, pass-through, GIF sampling, bomb guard) can be
/// tested without real image files or a real decoder.
private struct FakeImageEncoder: ImageEncoding {
    let inspection: ImageInspection
    let framePNG: Data

    init(width: Int, height: Int, format: String = "png", frameCount: Int = 1, frameDelays: [Double]? = nil, framePNG: Data = Data([9, 9, 9])) {
        self.inspection = ImageInspection(pixelWidth: width, pixelHeight: height, format: format, frameCount: frameCount, frameDelays: frameDelays)
        self.framePNG = framePNG
    }

    func inspect(url: URL) throws -> ImageInspection { inspection }
    func encodeFramePNG(url: URL, frameIndex: Int, maxLongEdge: Int) throws -> Data { framePNG }
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

private func makeGIF(frames: Int, width: Int, height: Int) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, frames, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
    for i in 0..<frames {
        CGImageDestinationAddImage(dest, makeImage(width: width, height: height, red: CGFloat(i) / CGFloat(frames)), frameProps)
    }
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

    @Test("Within-cap PNG is passed through byte-identical")
    func passThroughPNG() throws {
        let root = try makeVault()
        let bytes = Data("pretend png".utf8)
        try write(bytes, to: "notes/attachments/small.png", in: root)

        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 800, height: 600))
        let r = try reader.read(relativePath: "notes/attachments/small.png")
        #expect(r.totalFrames == 1)
        #expect(r.frames.count == 1)
        #expect(r.passedThrough == true)
        #expect(r.frames.first?.data == bytes)
        #expect(r.frames.first?.mimeType == "image/png")
        #expect(r.totalDurationSeconds == nil)               // stills carry no timing
        #expect(r.frames.first?.timeOffsetSeconds == nil)
    }

    @Test("Within-cap JPEG passes through with image/jpeg mime")
    func passThroughJPEG() throws {
        let root = try makeVault()
        let bytes = Data("pretend jpeg".utf8)
        try write(bytes, to: "notes/attachments/photo.jpg", in: root)

        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 800, height: 600))
        let r = try reader.read(relativePath: "notes/attachments/photo.jpg")
        #expect(r.passedThrough == true)
        #expect(r.frames.first?.mimeType == "image/jpeg")
        #expect(r.frames.first?.data == bytes)
    }

    @Test("Non-API format (heic) is re-encoded to PNG even when small")
    func heicReencoded() throws {
        let root = try makeVault()
        try write(Data([1, 2, 3]), to: "notes/attachments/photo.heic", in: root)

        let sentinel = Data([7, 7, 7])
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 800, height: 600, framePNG: sentinel))
        let r = try reader.read(relativePath: "notes/attachments/photo.heic")
        #expect(r.passedThrough == false)
        #expect(r.frames.first?.mimeType == "image/png")
        #expect(r.frames.first?.data == sentinel)
    }

    @Test("Oversized still is downscaled and re-encoded to PNG")
    func downscale() throws {
        let root = try makeVault()
        try write(Data([0, 1, 2]), to: "notes/attachments/wide.png", in: root)

        let sentinel = Data([7, 7, 7, 7])
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 5000, height: 1000, framePNG: sentinel))
        let r = try reader.read(relativePath: "notes/attachments/wide.png")
        #expect(r.passedThrough == false)
        #expect(r.frames.first?.data == sentinel)
        #expect(r.frames.first?.mimeType == "image/png")
    }

    @Test("Animated GIF returns a sampled PNG frame bundle")
    func animatedGIF() throws {
        let root = try makeVault()
        try write(Data([0]), to: "notes/attachments/anim.gif", in: root)

        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 400, height: 300, format: "gif", frameCount: 20))
        let r = try reader.read(relativePath: "notes/attachments/anim.gif")
        #expect(r.totalFrames == 20)
        #expect(r.frames.count == 8)                       // gifMaxFrames
        #expect(r.frames.allSatisfy { $0.mimeType == "image/png" })
        #expect(r.frames.first?.sourceIndex == 0)          // first frame
        #expect(r.frames.last?.sourceIndex == 19)          // last frame
    }

    @Test("Animated GIF surfaces total duration and per-frame time offsets")
    func gifTiming() throws {
        let root = try makeVault()
        try write(Data([0]), to: "notes/attachments/timed.gif", in: root)

        // 10 frames, 0.1s each → 1.0s total; each sampled frame's offset is index × 0.1.
        let delays = Array(repeating: 0.1, count: 10)
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 200, height: 200, format: "gif", frameCount: 10, frameDelays: delays))
        let r = try reader.read(relativePath: "notes/attachments/timed.gif")

        #expect(abs((r.totalDurationSeconds ?? -1) - 1.0) < 0.0001)
        #expect(r.frames.first?.timeOffsetSeconds == 0)    // frame 0 starts at t=0
        for frame in r.frames {
            let expected = Double(frame.sourceIndex) * 0.1
            #expect(abs((frame.timeOffsetSeconds ?? -1) - expected) < 0.0001)
        }
    }

    @Test("Animated GIF with no delay metadata leaves timing nil")
    func gifNoTiming() throws {
        let root = try makeVault()
        try write(Data([0]), to: "notes/attachments/untimed.gif", in: root)

        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 200, height: 200, format: "gif", frameCount: 12, frameDelays: nil))
        let r = try reader.read(relativePath: "notes/attachments/untimed.gif")
        #expect(r.totalDurationSeconds == nil)
        #expect(r.frames.allSatisfy { $0.timeOffsetSeconds == nil })
    }

    @Test("Single-frame GIF is treated as a still and passes through")
    func staticGIF() throws {
        let root = try makeVault()
        let bytes = Data("pretend gif".utf8)
        try write(bytes, to: "notes/attachments/still.gif", in: root)

        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 100, height: 100, format: "gif", frameCount: 1))
        let r = try reader.read(relativePath: "notes/attachments/still.gif")
        #expect(r.totalFrames == 1)
        #expect(r.frames.count == 1)
        #expect(r.passedThrough == true)
        #expect(r.frames.first?.mimeType == "image/gif")
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
        let tight = ImageManager.Config(maxLongEdge: 2576, maxFileBytes: 100, maxMegapixels: 50, gifMaxFrames: 8, gifFrameMaxLongEdge: 1280)
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 10, height: 10), config: tight)
        #expect(throws: ImageManager.ImageError.self) {
            try reader.read(relativePath: "notes/attachments/huge.png")
        }
    }

    @Test("Unsupported extension (svg) is rejected")
    func unsupportedExtension() throws {
        let root = try makeVault()
        let reader = ImageManager(vaultPath: root, encoder: FakeImageEncoder(width: 10, height: 10))
        #expect(throws: (any Error).self) {
            try reader.read(relativePath: "notes/attachments/vector.svg")
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

    @Test("Frame sampling is evenly spaced with first and last included")
    func sampling() {
        #expect(ImageManager.sampleIndices(total: 5, max: 8) == [0, 1, 2, 3, 4])
        #expect(ImageManager.sampleIndices(total: 8, max: 8) == Array(0..<8))
        let sampled = ImageManager.sampleIndices(total: 50, max: 8)
        #expect(sampled.count == 8)
        #expect(sampled.first == 0)
        #expect(sampled.last == 49)
        #expect(zip(sampled, sampled.dropFirst()).allSatisfy { $0 < $1 })   // strictly increasing
    }

    @Test("cumulativeTime sums the delays before a frame")
    func cumulativeTime() {
        let delays = [0.1, 0.2, 0.3, 0.4]
        #expect(ImageManager.cumulativeTime(delays: delays, before: 0) == 0)            // first frame
        #expect(abs(ImageManager.cumulativeTime(delays: delays, before: 2) - 0.3) < 1e-9)  // 0.1 + 0.2
        #expect(abs(ImageManager.cumulativeTime(delays: delays, before: 4) - 1.0) < 1e-9)  // all of them
        #expect(abs(ImageManager.cumulativeTime(delays: delays, before: 99) - 1.0) < 1e-9) // clamps past the end
    }
}

// MARK: - Real encoder + end-to-end

@Suite("CoreGraphicsImageEncoder")
struct CoreGraphicsImageEncoderTests {

    @Test("inspect reads dimensions, format, frame count")
    func inspect() throws {
        let root = try makeVault()
        try write(makePNG(width: 120, height: 80), to: "notes/attachments/real.png", in: root)
        let info = try CoreGraphicsImageEncoder().inspect(url: URL(fileURLWithPath: root + "/notes/attachments/real.png"))
        #expect(info.pixelWidth == 120)
        #expect(info.pixelHeight == 80)
        #expect(info.format == "png")
        #expect(info.frameCount == 1)
        #expect(info.frameDelays == nil)                   // a still carries no per-frame timing
    }

    @Test("inspect reads per-frame delays from a real animated GIF")
    func inspectGIFDelays() throws {
        let root = try makeVault()
        try write(makeGIF(frames: 5, width: 40, height: 40), to: "notes/attachments/delays.gif", in: root)
        let info = try CoreGraphicsImageEncoder().inspect(url: URL(fileURLWithPath: root + "/notes/attachments/delays.gif"))
        #expect(info.frameCount == 5)
        let delays = try #require(info.frameDelays)
        #expect(delays.count == 5)
        #expect(delays.allSatisfy { abs($0 - 0.1) < 0.02 })   // makeGIF writes 0.1s/frame
    }

    @Test("ImageManager passes a small real PNG through unchanged")
    func endToEndPassThrough() throws {
        let root = try makeVault()
        let png = makePNG(width: 300, height: 200)
        try write(png, to: "notes/attachments/screenshot.png", in: root)
        let r = try ImageManager(vaultPath: root, encoder: CoreGraphicsImageEncoder()).read(relativePath: "notes/attachments/screenshot.png")
        #expect(r.passedThrough == true)
        #expect(r.frames.first?.data == png)
    }

    @Test("ImageManager downscales a large real PNG to the cap")
    func endToEndDownscale() throws {
        let root = try makeVault()
        try write(makePNG(width: 4000, height: 100), to: "references/wide.png", in: root)
        let r = try ImageManager(vaultPath: root, encoder: CoreGraphicsImageEncoder()).read(relativePath: "references/wide.png")
        #expect(r.passedThrough == false)
        let firstFrame = try #require(r.frames.first)
        let size = try #require(pixelSize(of: firstFrame.data))
        #expect(max(size.width, size.height) <= 2576)
    }

    @Test("ImageManager reads a real JPEG (pass-through, image/jpeg)")
    func endToEndJPEG() throws {
        let root = try makeVault()
        let jpg = makeJPEG(width: 200, height: 150)
        try write(jpg, to: "notes/attachments/photo.jpg", in: root)
        let r = try ImageManager(vaultPath: root, encoder: CoreGraphicsImageEncoder()).read(relativePath: "notes/attachments/photo.jpg")
        #expect(r.frames.first?.mimeType == "image/jpeg")
        #expect(r.passedThrough == true)
    }

    @Test("ImageManager decomposes a real animated GIF into PNG frames")
    func endToEndAnimatedGIF() throws {
        let root = try makeVault()
        try write(makeGIF(frames: 12, width: 80, height: 60), to: "notes/attachments/anim.gif", in: root)
        let r = try ImageManager(vaultPath: root, encoder: CoreGraphicsImageEncoder()).read(relativePath: "notes/attachments/anim.gif")
        #expect(r.totalFrames == 12)
        #expect(r.frames.count == 8)
        // every returned frame is a valid PNG
        for frame in r.frames {
            #expect(frame.mimeType == "image/png")
            #expect(Array(frame.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        }
        // 12 frames × 0.1s ≈ 1.2s total; first frame at t=0, offsets non-decreasing.
        #expect(abs((r.totalDurationSeconds ?? 0) - 1.2) < 0.1)
        #expect(r.frames.first?.timeOffsetSeconds == 0)
        let offsets = r.frames.compactMap(\.timeOffsetSeconds)
        #expect(offsets.count == 8)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })   // strictly increasing in time
    }
}
