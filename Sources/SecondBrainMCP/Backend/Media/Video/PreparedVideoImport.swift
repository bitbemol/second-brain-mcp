import Foundation

/// Encoded GIF bytes and source metadata ready for generic vault persistence.
struct PreparedVideoImport: Sendable {
    /// Encoded animated GIF bytes.
    let data: Data
    /// Source display width after applying rotation metadata.
    let width: Int
    /// Source display height after applying rotation metadata.
    let height: Int
    /// Source duration in seconds.
    let durationSeconds: Double
    /// Number of frames written to the GIF.
    let frameCount: Int
    /// Effective sampling rate after applying the frame-count ceiling.
    let effectiveFramesPerSecond: Double
}
