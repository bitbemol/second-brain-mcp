import Foundation

/// Failures while loading video metadata, rendering frames, or encoding GIF data.
enum VideoEncodingError: Error, CustomStringConvertible {
    /// AVFoundation could not load required asset metadata.
    case cannotLoad(String)
    /// AVFoundation could not render a requested presentation time.
    case frameRenderFailed(String)
    /// ImageIO could not create or finalize the GIF output.
    case encodeFailed(String)

    /// Human-readable AVFoundation or ImageIO failure.
    var description: String {
        switch self {
        case .cannotLoad(let path): return "Cannot load video: \(path)"
        case .frameRenderFailed(let path): return "Failed to render a video frame: \(path)"
        case .encodeFailed(let path): return "Failed to encode GIF: \(path)"
        }
    }
}

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
    /// frames asynchronously (`AVAssetImageGenerator.image(at:)`). Returns the encoded
    /// artifact's measured dimensions, frame count, and stored timing—not source facts.
    func makeGIF(
        url: URL,
        atTimes times: [Double],
        frameDelay: Double,
        maxLongEdge: Int,
        maximumBytes: Int
    ) async throws -> PreparedVideoImport
}

extension VideoEncoding {
    /// Encodes without a byte ceiling for direct diagnostics and tests.
    func makeGIF(
        url: URL,
        atTimes times: [Double],
        frameDelay: Double,
        maxLongEdge: Int
    ) async throws -> PreparedVideoImport {
        try await makeGIF(
            url: url,
            atTimes: times,
            frameDelay: frameDelay,
            maxLongEdge: maxLongEdge,
            maximumBytes: .max
        )
    }
}

/// Lightweight video facts read without decoding frames.
struct VideoInspection: Sendable {
    /// Playable duration reported by the container, in seconds.
    let durationSeconds: Double
    /// Display dimensions (the natural size with the track's preferred transform
    /// applied, so a rotated portrait clip reports portrait dimensions — matching
    /// what `makeGIF` produces).
    let width: Int
    /// Display height after applying the track's preferred transform.
    let height: Int
    /// `false` for an audio-only file, a non-media file, or anything without a
    /// decodable video track — the signal `VideoImporter` rejects as "not a video".
    let hasVideoTrack: Bool
}
