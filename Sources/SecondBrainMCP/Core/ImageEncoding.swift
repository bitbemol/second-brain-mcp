import Foundation

/// Platform seam for the OS-specific image work.
///
/// Isolates the only platform-bound, hard-to-test piece — pixel inspection and
/// frame decode/encode — behind a protocol. This keeps `ImageManager`'s policy
/// (size caps, pass-through-vs-downscale, GIF frame sampling, the decode-bomb
/// guard) pure and unit-testable with a fake encoder, and lets a non-macOS
/// backend be added later without touching the policy. It is *not* a portability
/// claim: the rest of the server (PDFKit, AppKit, the mach RSS guard) is still
/// macOS-bound.
protocol ImageEncoding: Sendable {
    /// Read pixel dimensions, format, and frame count **without decoding pixels**.
    /// This is the decode-bomb guard: `ImageManager` rejects oversized images
    /// based on these dimensions before any decode happens.
    func inspect(url: URL) throws -> ImageInspection

    /// Decode one frame (0-indexed), downscale so its long edge is at most
    /// `maxLongEdge`, and re-encode to PNG. For a still image, frame 0 is the
    /// whole image; for an animated GIF, this extracts the given frame.
    func encodeFramePNG(url: URL, frameIndex: Int, maxLongEdge: Int) throws -> Data
}

/// Lightweight image facts read without decoding pixels.
struct ImageInspection: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let format: String   // lowercase extension-style tag, e.g. "png", "gif"
    let frameCount: Int  // >1 for an animated GIF; 1 for a still image
}
