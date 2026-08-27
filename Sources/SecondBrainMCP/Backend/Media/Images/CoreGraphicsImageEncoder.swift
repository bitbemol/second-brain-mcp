#if canImport(ImageIO)
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// macOS `ImageEncoding` backed by ImageIO / CoreGraphics. In-process, zero deps
/// (system framework), same trust surface as the PDFKit path already in the server.
/// It performs no subprocess execution.
struct CoreGraphicsImageEncoder: ImageEncoding {

    /// Error vocabulary belongs to the platform-neutral encoding boundary.
    typealias EncoderError = ImageEncodingError

    /// Reads format, dimensions, frame count, and GIF timing from metadata.
    func inspect(
        url: URL,
        maximumAnimationFrames: Int
    ) throws -> ImageInspection {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EncoderError.cannotOpen(url.lastPathComponent)
        }
        // Properties only — no pixel decode. This is what bounds the bomb risk.
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            throw EncoderError.missingDimensions(url.lastPathComponent)
        }

        let format: String
        if let uti = CGImageSourceGetType(source),
           let ext = UTType(uti as String)?.preferredFilenameExtension {
            format = ext.lowercased()
        } else {
            format = url.pathExtension.lowercased()
        }

        // Frame count is read from the index count, not by decoding frames.
        let frameCount = max(CGImageSourceGetCount(source), 1)
        if format == "gif", frameCount > max(maximumAnimationFrames, 0) {
            throw EncoderError.tooManyFrames(
                count: frameCount,
                limit: max(maximumAnimationFrames, 0)
            )
        }

        // Per-frame delays: metadata only (no pixel decode), GIFs only — a still or
        // a multi-page non-GIF carries no animation timing we'd surface.
        let frameDelays: [Double]? = (frameCount > 1 && format == "gif")
            ? (0..<frameCount).map { Self.gifDelay(source: source, index: $0) }
            : nil

        return ImageInspection(pixelWidth: width, pixelHeight: height, format: format, frameCount: frameCount, frameDelays: frameDelays)
    }

    /// One frame's display duration (seconds) from the GIF metadata. Prefers the
    /// *unclamped* delay (the file's true value); falls back to the clamped delay
    /// (which browsers floor to ~0.1s), then 0 when neither is present.
    private static func gifDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double,
           unclamped.isFinite,
           unclamped > 0 {
            return unclamped
        }
        guard let delay = gif[kCGImagePropertyGIFDelayTime] as? Double,
              delay.isFinite,
              delay > 0 else {
            return 0
        }
        return delay
    }

    /// Decodes a bounded image frame and encodes it as clean PNG data.
    func encodeFramePNG(url: URL, frameIndex: Int, maxLongEdge: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EncoderError.cannotOpen(url.lastPathComponent)
        }
        let count = max(CGImageSourceGetCount(source), 1)
        let index = min(max(frameIndex, 0), count - 1)

        // Decode the requested frame straight to a bounded size — ImageIO
        // downsamples during decode, so we never materialize the full-resolution
        // bitmap.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw EncoderError.decodeFailed(url.lastPathComponent)
        }

        // Re-encode to PNG (lossless — keeps text crisp, preserves alpha; drops EXIF).
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }
        return data as Data
    }
}
#endif
