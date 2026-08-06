import Foundation

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
