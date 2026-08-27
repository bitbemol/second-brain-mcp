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
        ) async throws -> PreparedVideoImport {
            if failMakeGIF { throw FakeError.boom }
            return PreparedVideoImport(
                data: gif, width: inspection.width, height: inspection.height,
                durationSeconds: frameDelay * Double(times.count), frameCount: times.count,
                effectiveFramesPerSecond: frameDelay > 0 ? 1 / frameDelay : 0
            )
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
        ) async throws -> PreparedVideoImport {
            await probe.enter()
            try await Task.sleep(for: .milliseconds(10))
            await probe.leave()
            return PreparedVideoImport(
                data: Data("GIF89a".utf8), width: 16, height: 16,
                durationSeconds: frameDelay * Double(times.count), frameCount: times.count,
                effectiveFramesPerSecond: frameDelay > 0 ? 1 / frameDelay : 0
            )
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
        ) async throws -> PreparedVideoImport {
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

    @Test("A generated MOV crosses the real GIF tool, storage, and Git boundaries")
    func realVideoToolImportSucceeds() async throws {
        let fixture = try MediaImportBoundaryFixture()
        defer { fixture.cleanup() }
        let source = try await makeTinyMOV(width: 64, height: 48, frames: 4, fps: 4)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let result = try await fixture.create(source: source, format: .gif)
        let stored = try await fixture.expectSuccessfulImport(result, source: source, format: .gif)
        #expect(try Data(contentsOf: source) == original)
        #expect(Array(stored.prefix(4)) == Array("GIF8".utf8))
        #expect(gifFrameCount(stored) > 1)
    }

    @Test("Prepared GIF facts describe encoded dimensions and quantized frame delays",
          arguments: [1, 3])
    func preparedGIFMetadataMatchesEncodedArtifact(_ maximumFrames: Int) async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = try await makeTinyMOV(width: 64, height: 48, frames: 10, fps: 10)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let prepared = try await VideoImporter(
            sourceValidator: ExternalFileSourceValidator(vaultPath: root),
            encoder: AVFoundationVideoEncoder(),
            configuration: metadataConfiguration(maximumFrames: maximumFrames)
        ).prepare(source: source.path)
        let facts = try encodedGIFFacts(prepared.data)
        #expect(facts.width == 32 && facts.height == 24)
        #expect(facts.frames == maximumFrames)
        if maximumFrames == 3 {
            // ImageIO stores centisecond delays, not the unquantized 1/3-second schedule.
            #expect(abs(facts.duration - 1) > 0.001)
        }
        #expect(prepared.width == facts.width)
        #expect(prepared.height == facts.height)
        #expect(prepared.frameCount == facts.frames)
        #expect(abs(prepared.durationSeconds - facts.duration) < 0.000_001)
        #expect(abs(prepared.effectiveFramesPerSecond
            - Double(facts.frames) / facts.duration) < 0.000_001)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test("GIF create and read summaries agree after resizing and frame-count capping")
    func gifCreateAndReadSummariesDescribeSameArtifact() async throws {
        let fixture = try MediaImportBoundaryFixture(
            videoConfiguration: metadataConfiguration(maximumFrames: 120)
        )
        defer { fixture.cleanup() }
        // Tiny pixels, but the same 25.9-second / 120-frame timing as the report.
        let source = try await makeTinyMOV(width: 64, height: 48, frames: 259, fps: 10)
        defer { try? FileManager.default.removeItem(at: source) }
        let created = try await fixture.create(source: source, format: .gif)
        let stored = try await fixture.expectSuccessfulImport(created, source: source, format: .gif)
        let facts = try encodedGIFFacts(stored)
        #expect(facts.width == 32 && facts.height == 24)
        #expect(facts.frames == 120)
        #expect(abs(facts.duration - 26.4) < 0.000_001)
        let read = try await FileToolController(readOnly: false, files: fixture.service).call(
            .init(name: "read_file", arguments: [
                "format": .string("gif"), "path": .string("notes/import.gif"),
            ])
        )
        #expect(read.isError != true)
        let createText = created.content.compactMap {
            if case .text(let text, _, _) = $0 { text } else { nil }
        }.joined()
        let readText = read.content.compactMap {
            if case .text(let text, _, _) = $0 { text } else { nil }
        }.joined()
        for expected in [
            "\(facts.width)×\(facts.height)",
            String(format: "%.1fs", facts.duration),
            "\(facts.frames) frames",
        ] {
            #expect(createText.contains(expected))
            #expect(readText.contains(expected))
        }
        #expect(!read.content.contains {
            if case .image = $0 { true } else { false }
        })
        let revision = FileSnapshot(data: stored, modifiedDate: nil).revision.rawValue
        #expect(createText.contains(revision))
        #expect(readText.contains(revision))
    }

    private func metadataConfiguration(maximumFrames: Int) -> VideoImportConfiguration {
        VideoImportConfiguration(
            fps: 10, maxLongEdge: 32, maxFrames: maximumFrames,
            maxSourceBytes: 1_048_576, maxDurationSeconds: 30,
            maxOutputBytes: 1_048_576
        )
    }

    /// Independent encoded-property oracle: never infers facts from video metadata or scheduling.
    private func encodedGIFFacts(_ data: Data) throws
        -> (width: Int, height: Int, frames: Int, duration: Double) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        let frames = CGImageSourceGetCount(source)
        var duration = 0.0
        for index in 0..<frames {
            let frame = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            )
            let gif = try #require(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let delay = try #require(
                (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            )
            #expect(delay.isFinite && delay > 0)
            duration += delay
        }
        return (width, height, frames, duration)
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
        let encoded = try await enc.makeGIF(url: mov, atTimes: schedule.times, frameDelay: schedule.frameDelay, maxLongEdge: 1080)
        let gif = encoded.data

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
