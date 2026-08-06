import Foundation

/// One model-compatible frame returned from a still or animated image.
struct ImageReadFrame: Sendable {
    /// Encoded frame bytes.
    let data: Data
    /// MIME type corresponding to ``data``.
    let mimeType: String
    /// Zero-based frame index in the source; zero for still images.
    let sourceIndex: Int
    /// Wall-clock offset from the animation start, or `nil` for still images
    /// and animations without timing metadata.
    let timeOffsetSeconds: Double?
}

/// Validated image metadata and transport-ready frame content.
struct ImageReadResult: Sendable {
    /// Vault-relative source path.
    let relativePath: String
    /// Concrete source format detected from image metadata.
    let format: FileFormat
    /// Original source width in pixels.
    let originalWidth: Int
    /// Original source height in pixels.
    let originalHeight: Int
    /// Original file size in bytes.
    let originalBytes: Int
    /// Source frame count; one for a still image.
    let totalFrames: Int
    /// Single still frame or sampled frames from an animated image.
    let frames: [ImageReadFrame]
    /// Whether a still image was returned byte-for-byte without re-encoding.
    let passedThrough: Bool
    /// Full animation duration, or `nil` for stills and missing timing metadata.
    let totalDurationSeconds: Double?
}
