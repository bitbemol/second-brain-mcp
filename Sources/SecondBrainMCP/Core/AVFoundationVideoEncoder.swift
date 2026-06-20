#if canImport(AVFoundation)
import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// macOS `VideoEncoding` backed by AVFoundation + ImageIO. In-process, zero deps
/// (system frameworks), same trust surface as the PDFKit / ImageIO paths already
/// in the server. No `Process()` and no ffmpeg — stays within Rule 4.
///
/// Inspection reads container/track metadata via `AVURLAsset` (async loads). The
/// GIF is assembled by `AVAssetImageGenerator` (one `copyCGImage` per requested
/// time, `maximumSize` downsamples on decode, `appliesPreferredTrackTransform`
/// fixes rotation) fed into a `CGImageDestination` of type GIF — the same ImageIO
/// machinery `CoreGraphicsImageEncoder` already uses, just in the write direction.
struct AVFoundationVideoEncoder: VideoEncoding {

    enum EncoderError: Error, CustomStringConvertible {
        case cannotLoad(String)
        case frameRenderFailed(String)
        case encodeFailed(String)

        var description: String {
            switch self {
            case .cannotLoad(let path): return "Cannot load video: \(path)"
            case .frameRenderFailed(let path): return "Failed to render a video frame: \(path)"
            case .encodeFailed(let path): return "Failed to encode GIF: \(path)"
            }
        }
    }

    func inspect(url: URL) async throws -> VideoInspection {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw EncoderError.cannotLoad(url.lastPathComponent)
        }

        let seconds = CMTimeGetSeconds(duration)
        let durationSeconds = (seconds.isFinite && seconds > 0) ? seconds : 0

        // Display dimensions = natural size with the preferred transform applied,
        // so a rotated track reports the orientation the GIF will actually have.
        var width = 0, height = 0
        if let track = videoTracks.first,
           let size = try? await track.load(.naturalSize) {
            if let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                width = Int(abs(rect.width).rounded())
                height = Int(abs(rect.height).rounded())
            } else {
                width = Int(size.width.rounded())
                height = Int(size.height.rounded())
            }
        }

        return VideoInspection(
            durationSeconds: durationSeconds,
            width: width,
            height: height,
            hasVideoTrack: !videoTracks.isEmpty
        )
    }

    func makeGIF(url: URL, atTimes times: [Double], frameDelay: Double, maxLongEdge: Int) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // honor rotation metadata
        // Exact frames (no tolerance) so evenly-spaced samples stay distinct.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Downscale-on-decode: fit each frame inside a maxLongEdge box (aspect kept),
        // so the full-resolution bitmap is never materialized.
        generator.maximumSize = CGSize(width: maxLongEdge, height: maxLongEdge)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.gif.identifier as CFString, max(times.count, 1), nil
        ) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }

        // Loop forever.
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        // Per-frame delay: write both the unclamped (true) and clamped values so
        // every reader paces it the same way `read_image` reads it back (it prefers
        // the unclamped delay, falls back to the clamped one).
        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                kCGImagePropertyGIFDelayTime: frameDelay
            ]
        ] as CFDictionary

        for seconds in times {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let frame: CGImage
            do {
                frame = try await generator.image(at: time).image
            } catch {
                throw EncoderError.frameRenderFailed(url.lastPathComponent)
            }
            CGImageDestinationAddImage(dest, frame, frameProps)
        }

        guard CGImageDestinationFinalize(dest) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }
        return data as Data
    }
}
#endif
