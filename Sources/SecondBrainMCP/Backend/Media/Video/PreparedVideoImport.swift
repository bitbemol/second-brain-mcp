import Foundation

/// Encoded GIF bytes and their measured metadata ready for generic vault persistence.
struct PreparedVideoImport: Sendable {
    /// Encoded animated GIF bytes.
    let data: Data
    /// Width of the encoded GIF in pixels, after rotation and resizing.
    let width: Int
    /// Height of the encoded GIF in pixels, after rotation and resizing.
    let height: Int
    /// Sum of the encoded GIF frame delays, including encoder quantization.
    let durationSeconds: Double
    /// Number of frames written to the GIF.
    let frameCount: Int
    /// Encoded frame count divided by stored duration; zero when timing is absent.
    let effectiveFramesPerSecond: Double
}
