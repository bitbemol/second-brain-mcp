import Foundation

/// Platform seam for the OS-specific video work.
///
/// The video twin of `ImageEncoding`: isolates the only platform-bound,
/// hard-to-test piece — video inspection and frame extraction / GIF assembly —
/// behind a protocol. This keeps `VideoImporter`'s policy (source caps, the
/// frame-schedule math, the output-size guard) pure and unit-testable with a fake
/// encoder, and lets a non-macOS backend be added later without touching the
/// policy. It is *not* a portability claim: the rest of the server (PDFKit,
/// AppKit, the mach RSS guard) is still macOS-bound.
///
/// `inspect` is `async` — unlike `ImageEncoding.inspect`, which is synchronous —
/// because AVFoundation loads container/track metadata asynchronously on modern
/// macOS. Bridging that to a synchronous call would mean blocking on a semaphore;
/// awaiting it keeps the cooperative thread pool free.
protocol VideoEncoding: Sendable {
    /// Read duration, display dimensions, and whether a video track exists
    /// **without decoding frames** — these come from the container/track metadata.
    /// `VideoImporter` uses this as the gate on the external source: a file that
    /// isn't a real video (no video track / no duration) is rejected before any
    /// frame is rendered, and an over-long clip is refused here.
    func inspect(url: URL) async throws -> VideoInspection

    /// Render frames at the requested presentation times (seconds), downscale so
    /// each frame's long edge is at most `maxLongEdge`, and assemble them into a
    /// single animated GIF that loops forever, displaying each frame for
    /// `frameDelay` seconds. Audio is ignored. `async` because AVFoundation renders
    /// frames asynchronously (`AVAssetImageGenerator.image(at:)`).
    func makeGIF(url: URL, atTimes times: [Double], frameDelay: Double, maxLongEdge: Int) async throws -> Data
}

/// Lightweight video facts read without decoding frames.
struct VideoInspection: Sendable {
    let durationSeconds: Double
    /// Display dimensions (the natural size with the track's preferred transform
    /// applied, so a rotated portrait clip reports portrait dimensions — matching
    /// what `makeGIF` produces).
    let width: Int
    let height: Int
    /// `false` for an audio-only file, a non-media file, or anything without a
    /// decodable video track — the signal `VideoImporter` rejects as "not a video".
    let hasVideoTrack: Bool
}
