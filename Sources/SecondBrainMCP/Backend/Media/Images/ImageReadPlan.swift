/// Encoding strategy used to produce model-compatible image frames.
enum ImageReadEncoding: Equatable, Sendable {
    /// Return the original source bytes with their native transport MIME type.
    case sourceBytes(mimeType: String)

    /// Decode selected source frames and encode them as bounded PNG data.
    case png(maximumLongEdge: Int)
}

/// Pure transport plan derived from validated image metadata and resource limits.
struct ImageReadPlan: Equatable, Sendable {
    /// Encoding strategy applied while executing the plan.
    let encoding: ImageReadEncoding

    /// Source frames to return, including animation timing offsets when available.
    let selections: [AnimatedImageFrameSampler.Selection]

    /// Frame count presented to callers; one for every non-animated image.
    let totalFrames: Int

    /// Complete animation duration, or `nil` for stills and missing timing metadata.
    let totalDurationSeconds: Double?

    /// Whether executing the plan returns the original bytes unchanged.
    var passedThrough: Bool {
        if case .sourceBytes = encoding { return true }
        return false
    }

    /// Builds the transport strategy for a concrete image format.
    ///
    /// Animated GIFs are sampled and converted to PNG frames. A still image passes
    /// through only when its format is accepted by MCP clients and its dimensions
    /// fit the configured cap; every other still is converted to PNG.
    ///
    /// - Parameters:
    ///   - format: Concrete format already verified against the source metadata.
    ///   - inspection: Source dimensions, frame count, and optional animation timing.
    ///   - limits: Output dimension and animation sampling limits.
    init(format: FileFormat, inspection: ImageInspection, limits: ImageLimits) {
        if format == .gif, inspection.frameCount > 1 {
            let sampling = AnimatedImageFrameSampler.plan(
                totalFrames: inspection.frameCount,
                maximumFrames: limits.gifMaxFrames,
                frameDelays: inspection.frameDelays
            )
            encoding = .png(maximumLongEdge: limits.gifFrameMaxLongEdge)
            selections = sampling.selections
            totalFrames = inspection.frameCount
            totalDurationSeconds = sampling.totalDurationSeconds
            return
        }

        let longEdge = max(inspection.pixelWidth, inspection.pixelHeight)
        if let mimeType = Self.nativeMIMEType[format], longEdge <= limits.maxLongEdge {
            encoding = .sourceBytes(mimeType: mimeType)
        } else {
            encoding = .png(maximumLongEdge: limits.maxLongEdge)
        }
        selections = [
            AnimatedImageFrameSampler.Selection(
                sourceIndex: 0,
                timeOffsetSeconds: nil
            )
        ]
        totalFrames = 1
        totalDurationSeconds = nil
    }

    /// Image formats MCP clients can consume without conversion.
    private static let nativeMIMEType: [FileFormat: String] = [
        .png: "image/png",
        .jpeg: "image/jpeg",
        .gif: "image/gif",
        .webp: "image/webp"
    ]
}
