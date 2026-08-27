#if canImport(AVFoundation)
import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// macOS `VideoEncoding` backed by AVFoundation + ImageIO. In-process, zero deps
/// (system frameworks), same trust surface as the PDFKit / ImageIO paths already
/// in the server. It uses neither `Process()` nor ffmpeg.
///
/// Inspection reads container/track metadata via `AVURLAsset` (async loads). The
/// GIF is assembled by `AVAssetImageGenerator` (one `copyCGImage` per requested
/// time, `maximumSize` downsamples on decode, `appliesPreferredTrackTransform`
/// fixes rotation) fed into a `CGImageDestination` of type GIF — the same ImageIO
/// machinery `CoreGraphicsImageEncoder` already uses, just in the write direction.
struct AVFoundationVideoEncoder: VideoEncoding {

    /// Error vocabulary belongs to the platform-neutral encoding boundary.
    typealias EncoderError = VideoEncodingError

    /// Loads duration, display dimensions, and track availability from metadata.
    func inspect(url: URL) async throws -> VideoInspection {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EncoderError.cannotLoad(url.lastPathComponent)
        }

        let seconds = CMTimeGetSeconds(duration)
        let durationSeconds = (seconds.isFinite && seconds > 0) ? seconds : 0

        // Display dimensions = natural size with the preferred transform applied,
        // so a rotated track reports the orientation the GIF will actually have.
        var width = 0, height = 0
        if let track = videoTracks.first {
            let size: CGSize
            do {
                size = try await track.load(.naturalSize)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw EncoderError.cannotLoad(url.lastPathComponent)
            }
            let displaySize: CGSize
            let transform: CGAffineTransform?
            do {
                transform = try await track.load(.preferredTransform)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                transform = nil
            }
            if let transform {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                displaySize = rect.size
            } else {
                displaySize = size
            }
            guard let dimensions = VideoPixelDimensions(
                width: Double(displaySize.width),
                height: Double(displaySize.height)
            ) else {
                throw EncoderError.cannotLoad(url.lastPathComponent)
            }
            width = dimensions.width
            height = dimensions.height
        }

        return VideoInspection(
            durationSeconds: durationSeconds,
            width: width,
            height: height,
            hasVideoTrack: !videoTracks.isEmpty
        )
    }

    /// Renders the requested video times and assembles a looping animated GIF.
    func makeGIF(
        url: URL,
        atTimes times: [Double],
        frameDelay: Double,
        maxLongEdge: Int,
        maximumBytes: Int
    ) async throws -> PreparedVideoImport {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // honor rotation metadata
        // Exact frames (no tolerance) so evenly-spaced samples stay distinct.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Downscale-on-decode: fit each frame inside a maxLongEdge box (aspect kept),
        // so the full-resolution bitmap is never materialized.
        generator.maximumSize = CGSize(width: maxLongEdge, height: maxLongEdge)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondBrainMCP-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appendingPathComponent("output.gif")
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            max(times.count, 1),
            nil
        ) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }

        // Loop forever.
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        // Per-frame delay: write both the unclamped (true) and clamped values so
        // every reader paces it the same way the image operation reads it (it prefers
        // the unclamped delay, falls back to the clamped one).
        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                kCGImagePropertyGIFDelayTime: frameDelay
            ]
        ] as CFDictionary

        for seconds in times {
            try Task.checkCancellation()
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let frame: CGImage
            do {
                frame = try await generator.image(at: time).image
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw EncoderError.frameRenderFailed(url.lastPathComponent)
            }
            CGImageDestinationAddImage(dest, frame, frameProps)
        }

        try Task.checkCancellation()
        guard CGImageDestinationFinalize(dest) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }
        let data = try BoundedFileReader.read(
            from: outputURL,
            maximumBytes: max(maximumBytes, 0),
            path: "prepared video GIF"
        )
        return try autoreleasepool {
            try Self.inspectGIF(data, maximumFrames: max(times.count, 1))
        }
    }

    /// Properties only: the final GIF owns its dimensions and centisecond timing.
    /// Read the already bounded bytes without another source read, pixel decode, or encode.
    private static func inspectGIF(_ data: Data, maximumFrames: Int) throws -> PreparedVideoImport {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw EncoderError.encodeFailed("prepared video GIF")
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrames else {
            throw EncoderError.encodeFailed("prepared video GIF")
        }
        var duration = 0.0
        for index in 0..<frameCount {
            try Task.checkCancellation()
            duration += CoreGraphicsImageEncoder.gifDelay(source: source, index: index)
        }
        return PreparedVideoImport(
            data: data, width: width, height: height,
            durationSeconds: duration, frameCount: frameCount,
            effectiveFramesPerSecond: duration > 0 ? Double(frameCount) / duration : 0
        )
    }
}
#endif
