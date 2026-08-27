import Foundation

/// Failures while inspecting, decoding, or encoding an image.
enum ImageEncodingError: Error, CustomStringConvertible {
    /// ImageIO could not construct an image source for the URL.
    case cannotOpen(String)
    /// Image metadata did not contain usable pixel dimensions.
    case missingDimensions(String)
    /// An animated source exceeds the metadata-inspection frame ceiling.
    case tooManyFrames(count: Int, limit: Int)
    /// ImageIO could not decode the requested frame.
    case decodeFailed(String)
    /// ImageIO could not create or finalize the PNG output.
    case encodeFailed(String)

    /// Human-readable ImageIO failure.
    var description: String {
        switch self {
        case .cannotOpen(let path): return "Cannot open image: \(path)"
        case .missingDimensions(let path): return "Image has no readable dimensions: \(path)"
        case .tooManyFrames(let count, let limit):
            return "Animated image has too many frames: \(count) (limit \(limit))"
        case .decodeFailed(let path): return "Failed to decode image: \(path)"
        case .encodeFailed(let path): return "Failed to encode image: \(path)"
        }
    }
}

/// Platform seam for the OS-specific image work.
///
/// Isolates the only platform-bound, hard-to-test piece — pixel inspection and
/// frame decode/encode — behind a protocol. This lets ``ImageReadPlan`` remain
/// pure, keeps resource enforcement testable with a fake encoder, and allows a
/// non-macOS encoder to be added later without touching transport policy. It is
/// *not* a portability claim: the rest of the server (PDFKit, AppKit, and the
/// mach RSS guard) is still macOS-bound.
protocol ImageEncoding: Sendable {
    /// Read pixel dimensions, format, frame count, and (for animated GIFs)
    /// per-frame delays **without decoding pixels** — these come from the image's
    /// metadata, not its bitmaps. This is the decode-bomb guard: `ImageReader`
    /// rejects oversized images based on these dimensions before any decode happens.
    func inspect(
        url: URL,
        maximumAnimationFrames: Int
    ) throws -> ImageInspection

    /// Decode one frame (0-indexed), downscale so its long edge is at most
    /// `maxLongEdge`, and re-encode to PNG. For a still image, frame 0 is the
    /// whole image; for an animated GIF, this extracts the given frame.
    func encodeFramePNG(url: URL, frameIndex: Int, maxLongEdge: Int) throws -> Data
}

extension ImageEncoding {
    /// Inspects without a frame ceiling for diagnostics that do not process timing.
    func inspect(url: URL) throws -> ImageInspection {
        try inspect(url: url, maximumAnimationFrames: .max)
    }
}

/// Lightweight image facts read without decoding pixels.
struct ImageInspection: Sendable {
    /// Source width in pixels.
    let pixelWidth: Int
    /// Source height in pixels.
    let pixelHeight: Int
    /// Lowercase, extension-style source format such as `png` or `gif`.
    let format: String
    /// Source frame count; one for a still image and more than one for animation.
    let frameCount: Int
    /// Per-frame display duration in seconds, one entry per source frame, in order.
    /// Populated only for animated GIFs; `nil` when timing is unavailable or N/A
    /// (still images, non-GIF formats). Lets `ImageReader` map a sampled frame to
    /// its wall-clock offset in the animation.
    let frameDelays: [Double]?
}
