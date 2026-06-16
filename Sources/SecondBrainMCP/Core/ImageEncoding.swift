import Foundation

/// Platform seam for the OS-specific image work.
///
/// Isolates the only platform-bound, hard-to-test piece — pixel inspection and
/// decode/encode — behind a protocol. This keeps `ImageManager`'s policy (size
/// caps, the pass-through-vs-downscale decision, the decode-bomb guard) pure and
/// unit-testable with a fake encoder, and lets a non-macOS backend be added later
/// without touching the policy. It is *not* a portability claim: the rest of the
/// server (PDFKit, AppKit, the mach RSS guard) is still macOS-bound.
protocol ImageEncoding: Sendable {
    /// Read pixel dimensions and format **without decoding pixels**.
    /// This is the decode-bomb guard: `ImageManager` rejects oversized images
    /// based on these dimensions before any decode happens.
    func inspect(url: URL) throws -> ImageInspection

    /// Decode, downscale so the long edge is at most `maxLongEdge`, and re-encode
    /// to PNG. Only called when the source exceeds the caps — within-cap images
    /// are passed through untouched by the caller.
    func encodeDownscaledPNG(url: URL, maxLongEdge: Int) throws -> Data
}

/// Lightweight image facts read without decoding pixels.
struct ImageInspection: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let format: String   // lowercase extension-style tag, e.g. "png"
}
