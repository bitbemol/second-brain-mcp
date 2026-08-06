/// Pure frame timing plan for video-to-GIF conversion.
struct VideoFrameSchedule: Equatable, Sendable {
    /// Source timestamps to render, in seconds from the video start.
    let times: [Double]
    /// Display duration assigned to every encoded GIF frame.
    let frameDelay: Double

    /// Builds an evenly distributed schedule across the complete source duration.
    ///
    /// A short clip uses the requested sampling rate. A longer clip is capped at
    /// `maximumFrames` and spreads those frames across `[0, duration)`. At least
    /// one frame is produced, including for a zero-duration test value.
    ///
    /// - Parameters:
    ///   - duration: Source duration in seconds.
    ///   - framesPerSecond: Target sampling rate before the frame-count ceiling.
    ///   - maximumFrames: Maximum frames permitted in the encoded GIF.
    init(
        duration: Double,
        framesPerSecond: Double,
        maximumFrames: Int
    ) {
        let safeDuration = max(duration, 0)
        let requestedFrames = Int((safeDuration * framesPerSecond).rounded(.up))
        let frameCount = max(1, min(requestedFrames, max(maximumFrames, 1)))

        frameDelay = safeDuration / Double(frameCount)
        times = (0..<frameCount).map { index in
            Double(index) * safeDuration / Double(frameCount)
        }
    }
}
