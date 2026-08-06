/// Produces an evenly distributed, timing-aware animated-image sampling plan.
enum AnimatedImageFrameSampler {
    /// One selected source frame and its optional animation time offset.
    struct Selection: Equatable, Sendable {
        /// Zero-based frame index in the source animation.
        let sourceIndex: Int
        /// Seconds from the animation start, or `nil` when timing is unavailable.
        let timeOffsetSeconds: Double?
    }

    /// Selected frames plus the complete source animation duration.
    struct Plan: Equatable, Sendable {
        /// Frames selected for decoding in source order.
        let selections: [Selection]
        /// Sum of all source frame delays, when timing metadata is available.
        let totalDurationSeconds: Double?
    }

    /// Builds a frame sampling plan from source metadata.
    ///
    /// The first and last frames are always included when sampling is necessary.
    /// Timing offsets preserve the source animation's pacing rather than assuming
    /// every frame has an equal duration.
    ///
    /// - Parameters:
    ///   - totalFrames: Number of frames reported by the source image.
    ///   - maximumFrames: Maximum frames to return for model transport.
    ///   - frameDelays: Optional source-frame durations in seconds.
    /// - Returns: Ordered selections and the optional complete duration.
    static func plan(
        totalFrames: Int,
        maximumFrames: Int,
        frameDelays: [Double]?
    ) -> Plan {
        let selections = sampleIndices(total: totalFrames, maximum: maximumFrames)
            .map { index in
                Selection(
                    sourceIndex: index,
                    timeOffsetSeconds: frameDelays.map {
                        timeOffset(delays: $0, before: index)
                    }
                )
            }
        return Plan(
            selections: selections,
            totalDurationSeconds: frameDelays.map { $0.reduce(0, +) }
        )
    }

    /// Returns evenly spaced indices with the first and last always included.
    static func sampleIndices(total: Int, maximum: Int) -> [Int] {
        guard total > maximum else {
            return Array(0..<Swift.max(total, 0))
        }
        guard maximum > 1 else { return [0] }
        return (0..<maximum).map { index in
            Int(
                (Double(index) * Double(total - 1) / Double(maximum - 1))
                    .rounded()
            )
        }
    }

    /// Sums source frame delays before an index to obtain its wall-clock offset.
    ///
    /// Prefixing naturally clamps an index beyond the delay list, allowing
    /// incomplete metadata to degrade gracefully.
    static func timeOffset(delays: [Double], before index: Int) -> Double {
        guard index > 0 else { return 0 }
        return delays.prefix(index).reduce(0, +)
    }
}
