import Testing
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import SecondBrainMCP

@Suite("VideoImporter")
struct VideoImporterTests {

    // MARK: - Helpers

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "VideoImporter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return root
    }

    /// A unique path OUTSIDE the vault, to stand in for an arbitrary source file.
    private func srcPath(_ name: String) -> String {
        NSTemporaryDirectory() + "vidimport-src-\(UUID().uuidString)-\(name)"
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// GIF bytes with a valid header and a target total length — enough for the
    /// fake encoder's output (the importer only writes them and checks size).
    private func gifData(byteCount: Int) -> Data {
        var d = Data("GIF89a".utf8)
        if byteCount > d.count { d.append(Data(count: byteCount - d.count)) }
        return d
    }

    private func validInspection(duration: Double = 2, width: Int = 320, height: Int = 240) -> VideoInspection {
        VideoInspection(durationSeconds: duration, width: width, height: height, hasVideoTrack: true)
    }

    /// Fake `VideoEncoding` — canned inspection + GIF bytes so the policy in
    /// `VideoImporter` can be tested without a real video on disk.
    private struct FakeVideoEncoder: VideoEncoding {
        var inspection: VideoInspection
        var gif: Data
        var failInspect = false
        var failMakeGIF = false

        enum FakeError: Error { case boom }

        func inspect(url: URL) async throws -> VideoInspection {
            if failInspect { throw FakeError.boom }
            return inspection
        }
        func makeGIF(url: URL, atTimes times: [Double], frameDelay: Double, maxLongEdge: Int) async throws -> Data {
            if failMakeGIF { throw FakeError.boom }
            return gif
        }
    }

    /// Generate a tiny real `.mov` (`frames` solid-color frames at `fps`) in a temp
    /// dir via AVAssetWriter — the fixture for the real-encoder end-to-end tests.
    /// Verified to run headlessly under `swift test`.
    private func makeTinyMOV(width: Int = 64, height: Int = 48, frames: Int = 10, fps: Int = 10) async throws -> URL {
        let url = URL(fileURLWithPath: srcPath("clip.mov"))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pbAttrs)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, pbAttrs as CFDictionary, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )!
            ctx.setFillColor(CGColor(red: CGFloat(i) / CGFloat(frames), green: 0, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        return url
    }

    private func gifFrameCount(_ data: Data) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    // MARK: - Frame-schedule math (pure)

    @Test("Short clip is sampled at full fps")
    func scheduleShortClip() {
        // 2s × 10fps = 20 frames; spaced every 0.1s across [0, 2).
        let s = VideoImporter.frameSchedule(duration: 2.0, fps: 10, maxFrames: 120)
        #expect(s.times.count == 20)
        #expect(abs(s.frameDelay - 0.1) < 1e-9)
        #expect(s.times.first == 0)
        #expect(s.times.last! < 2.0)
        // Evenly spaced.
        #expect(abs(s.times[1] - 0.1) < 1e-9)
    }

    @Test("Long clip spreads evenly across the whole video within maxFrames")
    func scheduleLongClip() {
        // 100s × 10fps would be 1000 frames; capped at 120 spread across the clip.
        let s = VideoImporter.frameSchedule(duration: 100, fps: 10, maxFrames: 120)
        #expect(s.times.count == 120)
        #expect(abs(s.frameDelay - 100.0 / 120.0) < 1e-9)
        #expect(s.times.first == 0)
        #expect(s.times.last! < 100)
        #expect(s.times.last! > 99)   // (119/120)·100 ≈ 99.17 — reaches the tail
    }

    @Test("A sub-frame clip still yields exactly one frame")
    func scheduleOneFrameEdge() {
        let s = VideoImporter.frameSchedule(duration: 0.05, fps: 10, maxFrames: 120)
        #expect(s.times == [0])
        #expect(abs(s.frameDelay - 0.05) < 1e-9)
    }

    @Test("A zero-duration clip degrades to one frame, no NaN")
    func scheduleZeroDuration() {
        let s = VideoImporter.frameSchedule(duration: 0, fps: 10, maxFrames: 120)
        #expect(s.times == [0])
        #expect(s.frameDelay == 0)
    }

    // MARK: - Destination normalization

    @Test("Destination extension is normalized to .gif")
    func normalizesExtension() {
        #expect(VideoImporter.normalizedDestination("notes/a/clip.mov") == "notes/a/clip.gif")
        #expect(VideoImporter.normalizedDestination("notes/a/clip") == "notes/a/clip.gif")
        #expect(VideoImporter.normalizedDestination("  notes/a/clip.mp4 ") == "notes/a/clip.gif")
    }

    // MARK: - Policy (fake encoder)

    @Test("Happy path writes a .gif and leaves the source untouched")
    func happyPath() async throws {
        let root = try makeVault()
        let src = srcPath("clip.mov")
        try Data(count: 4096).write(to: URL(fileURLWithPath: src))   // source is faked; bytes don't matter
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 256))

        let r = try await VideoImporter(vaultPath: root, encoder: enc)
            .add(source: src, destination: "notes/clips/demo.mov")

        #expect(r.destination == "notes/clips/demo.gif")           // normalized to .gif
        #expect(r.width == 320 && r.height == 240)
        #expect(r.frameCount == 20)                                 // 2s × 10fps
        #expect(r.bytesWritten == 256)
        #expect(exists(src))                                        // source only read, never touched
        let stored = try Data(contentsOf: URL(fileURLWithPath: root + "/notes/clips/demo.gif"))
        #expect(Array(stored.prefix(4)) == Array("GIF8".utf8))
    }

    @Test("A non-video source (no video track) is rejected, nothing written")
    func rejectsNonVideo() async throws {
        let root = try makeVault()
        let src = srcPath("audio.m4a")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        let enc = FakeVideoEncoder(
            inspection: VideoInspection(durationSeconds: 5, width: 0, height: 0, hasVideoTrack: false),
            gif: gifData(byteCount: 64)
        )
        let importer = VideoImporter(vaultPath: root, encoder: enc)

        await #expect(throws: VideoImporter.VideoImporterError.self) {
            try await importer.add(source: src, destination: "notes/x.gif")
        }
        #expect(!exists(root + "/notes/x.gif"))
    }

    @Test("A clip longer than the duration cap is rejected")
    func rejectsTooLong() async throws {
        let root = try makeVault()
        let src = srcPath("long.mov")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        let tight = VideoImporter.Config(fps: 10, maxLongEdge: 1080, maxFrames: 120, maxSourceBytes: 512 << 20, maxDurationSeconds: 1, maxOutputBytes: 50 << 20)
        let enc = FakeVideoEncoder(inspection: validInspection(duration: 10), gif: gifData(byteCount: 64))
        let importer = VideoImporter(vaultPath: root, encoder: enc, config: tight)

        await #expect(throws: VideoImporter.VideoImporterError.self) {
            try await importer.add(source: src, destination: "notes/x.gif")
        }
    }

    @Test("The output-size guard rejects an oversized GIF, nothing written")
    func rejectsOversizedOutput() async throws {
        let root = try makeVault()
        let src = srcPath("clip.mov")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        // makeGIF returns 100 bytes; cap is 10.
        let tight = VideoImporter.Config(fps: 10, maxLongEdge: 1080, maxFrames: 120, maxSourceBytes: 512 << 20, maxDurationSeconds: 1800, maxOutputBytes: 10)
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 100))
        let importer = VideoImporter(vaultPath: root, encoder: enc, config: tight)

        await #expect(throws: VideoImporter.VideoImporterError.self) {
            try await importer.add(source: src, destination: "notes/x.gif")
        }
        #expect(!exists(root + "/notes/x.gif"))   // rejected before writing
    }

    @Test("Source larger than the size cap is rejected before conversion")
    func rejectsOversizeSource() async throws {
        let root = try makeVault()
        let src = srcPath("big.mov")
        try Data(count: 2000).write(to: URL(fileURLWithPath: src))
        let tight = VideoImporter.Config(fps: 10, maxLongEdge: 1080, maxFrames: 120, maxSourceBytes: 1000, maxDurationSeconds: 1800, maxOutputBytes: 50 << 20)
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(vaultPath: root, encoder: enc, config: tight)

        do {
            _ = try await importer.add(source: src, destination: "notes/x.gif")
            Issue.record("expected the import to be rejected for source size")
        } catch let e as VideoImporter.VideoImporterError {
            guard case .sourceTooLarge = e else {
                Issue.record("expected sourceTooLarge, got: \(e)")
                return
            }
        }
    }

    @Test("Missing source is rejected")
    func rejectsMissingSource() async throws {
        let root = try makeVault()
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(vaultPath: root, encoder: enc)
        await #expect(throws: VideoImporter.VideoImporterError.self) {
            try await importer.add(source: srcPath("nope.mov"), destination: "notes/x.gif")
        }
    }

    @Test("Destination outside notes/ is rejected")
    func rejectsOutsideNotes() async throws {
        let root = try makeVault()
        let src = srcPath("clip.mov")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(vaultPath: root, encoder: enc)

        await #expect(throws: VideoImporter.VideoImporterError.self) {
            try await importer.add(source: src, destination: "references/x.gif")
        }
    }

    @Test("Existing destination is not clobbered")
    func rejectsExisting() async throws {
        let root = try makeVault()
        try FileManager.default.createDirectory(atPath: root + "/notes/a", withIntermediateDirectories: true)
        try Data([0]).write(to: URL(fileURLWithPath: root + "/notes/a/taken.gif"))
        let src = srcPath("clip.mov")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(vaultPath: root, encoder: enc)

        await #expect(throws: VideoImporter.VideoImporterError.self) {
            try await importer.add(source: src, destination: "notes/a/taken.gif")
        }
    }

    @Test("A source inside the vault is rejected (add_video is for external files)")
    func rejectsInVaultSource() async throws {
        let root = try makeVault()
        try FileManager.default.createDirectory(atPath: root + "/notes/_attachments", withIntermediateDirectories: true)
        let inVault = root + "/notes/_attachments/existing.mov"
        try Data(count: 1024).write(to: URL(fileURLWithPath: inVault))
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(vaultPath: root, encoder: enc)

        await #expect(throws: VideoImporter.VideoImporterError.self) {
            try await importer.add(source: inVault, destination: "notes/copy.gif")
        }
        #expect(exists(inVault))   // untouched
    }

    // MARK: - End-to-end with the real AVFoundation encoder

    @Test("Real encoder: inspect reports duration/dims/hasVideoTrack")
    func realEncoderInspect() async throws {
        let mov = try await makeTinyMOV(width: 64, height: 48, frames: 10, fps: 10)
        defer { try? FileManager.default.removeItem(at: mov) }

        let info = try await AVFoundationVideoEncoder().inspect(url: mov)
        #expect(info.hasVideoTrack)
        #expect(info.width == 64 && info.height == 48)
        #expect(abs(info.durationSeconds - 1.0) < 0.25)   // 10 frames @ 10fps ≈ 1s
    }

    @Test("Real encoder: makeGIF returns GIF8 bytes decoding to N frames")
    func realEncoderMakeGIF() async throws {
        let mov = try await makeTinyMOV(width: 64, height: 48, frames: 10, fps: 10)
        defer { try? FileManager.default.removeItem(at: mov) }

        let enc = AVFoundationVideoEncoder()
        let info = try await enc.inspect(url: mov)
        let schedule = VideoImporter.frameSchedule(duration: info.durationSeconds, fps: 10, maxFrames: 120)
        let gif = try await enc.makeGIF(url: mov, atTimes: schedule.times, frameDelay: schedule.frameDelay, maxLongEdge: 1080)

        #expect(Array(gif.prefix(4)) == Array("GIF8".utf8))
        #expect(gifFrameCount(gif) == schedule.times.count)
    }

    @Test("Real encoder: add() imports a generated .mov as a .gif, source untouched")
    func realEncoderImport() async throws {
        let root = try makeVault()
        let mov = try await makeTinyMOV(width: 48, height: 32, frames: 8, fps: 8)
        defer { try? FileManager.default.removeItem(at: mov) }

        let r = try await VideoImporter(vaultPath: root, encoder: AVFoundationVideoEncoder())
            .add(source: mov.path, destination: "notes/clips/rec.mov")

        #expect(r.destination == "notes/clips/rec.gif")
        #expect(r.frameCount >= 1)
        #expect(exists(root + "/notes/clips/rec.gif"))
        #expect(exists(mov.path))   // source only read, never touched
        let stored = try Data(contentsOf: URL(fileURLWithPath: root + "/notes/clips/rec.gif"))
        #expect(Array(stored.prefix(4)) == Array("GIF8".utf8))
        #expect(gifFrameCount(stored) == r.frameCount)
    }
}
