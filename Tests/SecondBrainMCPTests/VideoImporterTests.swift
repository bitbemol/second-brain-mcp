import Testing
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import second_brain_mcp

@Suite
struct `VideoImporter tests` {

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
        func makeGIF(
            url: URL,
            atTimes times: [Double],
            frameDelay: Double,
            maxLongEdge: Int,
            maximumBytes: Int
        ) async throws -> Data {
            if failMakeGIF { throw FakeError.boom }
            return gif
        }
    }

    private actor ConversionProbe {
        private var active = 0
        private(set) var maximumActive = 0

        func enter() {
            active += 1
            maximumActive = max(maximumActive, active)
        }

        func leave() {
            active -= 1
        }
    }

    private struct TrackingVideoEncoder: VideoEncoding {
        let probe: ConversionProbe

        func inspect(url: URL) async throws -> VideoInspection {
            await probe.enter()
            try await Task.sleep(for: .milliseconds(10))
            await probe.leave()
            return VideoInspection(
                durationSeconds: 0.1,
                width: 16,
                height: 16,
                hasVideoTrack: true
            )
        }

        func makeGIF(
            url: URL,
            atTimes times: [Double],
            frameDelay: Double,
            maxLongEdge: Int,
            maximumBytes: Int
        ) async throws -> Data {
            await probe.enter()
            try await Task.sleep(for: .milliseconds(10))
            await probe.leave()
            return Data("GIF89a".utf8)
        }
    }

    private struct CancellingVideoEncoder: VideoEncoding {
        let cancelDuringInspection: Bool

        func inspect(url: URL) async throws -> VideoInspection {
            if cancelDuringInspection { throw CancellationError() }
            return VideoInspection(
                durationSeconds: 1,
                width: 16,
                height: 16,
                hasVideoTrack: true
            )
        }

        func makeGIF(
            url: URL,
            atTimes times: [Double],
            frameDelay: Double,
            maxLongEdge: Int,
            maximumBytes: Int
        ) async throws -> Data {
            throw CancellationError()
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

    // MARK: - Policy (fake encoder)

    @Test
    func `Happy path prepares GIF data and leaves the source untouched`() async throws {
        let root = try makeVault()
        let src = srcPath("clip.mov")
        try Data(count: 4096).write(to: URL(fileURLWithPath: src))   // source is faked; bytes don't matter
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 256))

        let prepared = try await VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: enc
        )
            .prepare(source: src)

        #expect(prepared.width == 320 && prepared.height == 240)
        #expect(prepared.frameCount == 20)
        #expect(prepared.data.count == 256)
        #expect(Array(prepared.data.prefix(4)) == Array("GIF8".utf8))
        #expect(exists(src))
    }

    @Test
    func `Concurrent requests serialize complete video conversions`() async throws {
        let root = try makeVault()
        let sources = try (0..<4).map { index in
            let source = srcPath("clip-\(index).mov")
            try Data(count: 64).write(to: URL(fileURLWithPath: source))
            return source
        }
        let probe = ConversionProbe()
        let importer = VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: TrackingVideoEncoder(probe: probe)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    _ = try await importer.prepare(source: source)
                }
            }
            try await group.waitForAll()
        }

        #expect(await probe.maximumActive == 1)
    }

    @Test
    func `Video inspection and encoding preserve cancellation`() async throws {
        let root = try makeVault()
        let source = srcPath("cancel.mov")
        try Data(count: 64).write(to: URL(fileURLWithPath: source))

        for cancelDuringInspection in [true, false] {
            let importer = VideoImporter(
                sourceValidator: ExternalFileSourceValidator(vaultPath: root),
                encoder: CancellingVideoEncoder(
                    cancelDuringInspection: cancelDuringInspection
                )
            )
            await #expect(throws: CancellationError.self) {
                _ = try await importer.prepare(source: source)
            }
        }
    }

    @Test
    func `A non-video source (no video track) is rejected, nothing written`() async throws {
        let root = try makeVault()
        let src = srcPath("audio.m4a")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        let enc = FakeVideoEncoder(
            inspection: VideoInspection(durationSeconds: 5, width: 0, height: 0, hasVideoTrack: false),
            gif: gifData(byteCount: 64)
        )
        let importer = VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: enc
        )

        await #expect(throws: VideoImportError.self) {
            try await importer.prepare(source: src)
        }
    }

    @Test
    func `A clip longer than the duration cap is rejected`() async throws {
        let root = try makeVault()
        let src = srcPath("long.mov")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        let tight = VideoImportConfiguration(
            fps: 10,
            maxLongEdge: 1080,
            maxFrames: 120,
            maxSourceBytes: 512 << 20,
            maxDurationSeconds: 1,
            maxOutputBytes: 50 << 20
        )
        let enc = FakeVideoEncoder(
            inspection: validInspection(duration: 10),
            gif: gifData(byteCount: 64)
        )
        let importer = VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: enc,
            configuration: tight
        )

        await #expect(throws: VideoImportError.self) {
            try await importer.prepare(source: src)
        }
    }

    @Test
    func `The output-size guard rejects an oversized GIF, nothing written`() async throws {
        let root = try makeVault()
        let src = srcPath("clip.mov")
        try Data(count: 1024).write(to: URL(fileURLWithPath: src))
        // makeGIF returns 100 bytes; cap is 10.
        let tight = VideoImportConfiguration(
            fps: 10,
            maxLongEdge: 1080,
            maxFrames: 120,
            maxSourceBytes: 512 << 20,
            maxDurationSeconds: 1800,
            maxOutputBytes: 10
        )
        let enc = FakeVideoEncoder(
            inspection: validInspection(),
            gif: gifData(byteCount: 100)
        )
        let importer = VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: enc,
            configuration: tight
        )

        await #expect(throws: VideoImportError.self) {
            try await importer.prepare(source: src)
        }
    }

    @Test
    func `Source larger than the size cap is rejected before conversion`() async throws {
        let root = try makeVault()
        let src = srcPath("big.mov")
        try Data(count: 2000).write(to: URL(fileURLWithPath: src))
        let tight = VideoImportConfiguration(
            fps: 10,
            maxLongEdge: 1080,
            maxFrames: 120,
            maxSourceBytes: 1000,
            maxDurationSeconds: 1800,
            maxOutputBytes: 50 << 20
        )
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: enc,
            configuration: tight
        )

        do {
            _ = try await importer.prepare(source: src)
            Issue.record("expected the import to be rejected for source size")
        } catch let e as ExternalFileSourceValidator.ValidationError {
            guard case .sourceTooLarge = e else {
                Issue.record("expected sourceTooLarge, got: \(e)")
                return
            }
        }
    }

    @Test
    func `Missing source is rejected`() async throws {
        let root = try makeVault()
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: enc
        )
        await #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try await importer.prepare(source: srcPath("nope.mov"))
        }
    }

    @Test
    func `A source inside the vault is rejected`() async throws {
        let root = try makeVault()
        try FileManager.default.createDirectory(atPath: root + "/notes/_attachments", withIntermediateDirectories: true)
        let inVault = root + "/notes/_attachments/existing.mov"
        try Data(count: 1024).write(to: URL(fileURLWithPath: inVault))
        let enc = FakeVideoEncoder(inspection: validInspection(), gif: gifData(byteCount: 64))
        let importer = VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: enc
        )

        await #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try await importer.prepare(source: inVault)
        }
        #expect(exists(inVault))   // untouched
    }

    // MARK: - End-to-end with the real AVFoundation encoder

    @Test
    func `Real encoder: inspect reports duration/dims/hasVideoTrack`() async throws {
        let mov = try await makeTinyMOV(width: 64, height: 48, frames: 10, fps: 10)
        defer { try? FileManager.default.removeItem(at: mov) }

        let info = try await AVFoundationVideoEncoder().inspect(url: mov)
        #expect(info.hasVideoTrack)
        #expect(info.width == 64 && info.height == 48)
        #expect(abs(info.durationSeconds - 1.0) < 0.25)   // 10 frames @ 10fps ≈ 1s
    }

    @Test
    func `Real encoder: makeGIF returns GIF8 bytes decoding to N frames`() async throws {
        let mov = try await makeTinyMOV(width: 64, height: 48, frames: 10, fps: 10)
        defer { try? FileManager.default.removeItem(at: mov) }

        let enc = AVFoundationVideoEncoder()
        let info = try await enc.inspect(url: mov)
        let schedule = VideoFrameSchedule(
            duration: info.durationSeconds,
            framesPerSecond: 10,
            maximumFrames: 120
        )
        let gif = try await enc.makeGIF(url: mov, atTimes: schedule.times, frameDelay: schedule.frameDelay, maxLongEdge: 1080)

        #expect(Array(gif.prefix(4)) == Array("GIF8".utf8))
        #expect(gifFrameCount(gif) == schedule.times.count)
    }

    @Test
    func `Real encoder prepares a generated MOV as GIF data`() async throws {
        let root = try makeVault()
        let mov = try await makeTinyMOV(width: 48, height: 32, frames: 8, fps: 8)
        defer { try? FileManager.default.removeItem(at: mov) }

        let prepared = try await VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: AVFoundationVideoEncoder()
        )
            .prepare(source: mov.path)

        #expect(prepared.frameCount >= 1)
        #expect(exists(mov.path))
        #expect(Array(prepared.data.prefix(4)) == Array("GIF8".utf8))
        #expect(gifFrameCount(prepared.data) == prepared.frameCount)
    }
}
