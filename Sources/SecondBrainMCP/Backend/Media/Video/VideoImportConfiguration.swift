/// Resource and fidelity policy for external video-to-GIF conversion.
struct VideoImportConfiguration: Sendable {
    /// Target sampling rate for clips below the frame-count ceiling.
    let fps: Double
    /// Long-edge cap for every encoded GIF frame.
    let maxLongEdge: Int
    /// Maximum number of frames sampled from one source video.
    let maxFrames: Int
    /// Maximum external source size before video inspection.
    let maxSourceBytes: Int
    /// Maximum accepted source duration in seconds.
    let maxDurationSeconds: Double
    /// Maximum encoded GIF size accepted for vault persistence.
    let maxOutputBytes: Int

    /// Balanced production policy for video-to-GIF conversion.
    static let `default` = VideoImportConfiguration(
        fps: 10,
        maxLongEdge: 1080,
        maxFrames: 120,
        maxSourceBytes: 512 * 1024 * 1024,
        maxDurationSeconds: 1800,
        maxOutputBytes: FileFormat.gif.maximumFileBytes
    )
}
