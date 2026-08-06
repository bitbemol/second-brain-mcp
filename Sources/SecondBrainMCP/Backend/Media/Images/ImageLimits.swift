/// Resource and output limits shared by image reading and importing.
///
/// Keeping these values independent from either operation prevents one feature
/// from depending on another feature's implementation type.
struct ImageLimits: Sendable {
    /// Long-edge cap for a still image returned through the MCP transport.
    let maxLongEdge: Int
    /// Hard source/output size limit; production derives it from PNG policy.
    let maxFileBytes: Int
    /// Decode-bomb limit expressed in source megapixels.
    let maxMegapixels: Double
    /// Maximum number of frames sampled from an animated GIF.
    let gifMaxFrames: Int
    /// Maximum source GIF frames inspected before rejecting adversarial metadata.
    let gifMaxSourceFrames: Int
    /// Long-edge cap for each sampled animated-GIF frame.
    let gifFrameMaxLongEdge: Int

    /// Balanced production limits used by image reads and imports.
    static let `default` = ImageLimits(
        maxLongEdge: 2576,
        maxFileBytes: FileFormat.png.maximumFileBytes,
        maxMegapixels: 50,
        gifMaxFrames: 8,
        gifMaxSourceFrames: 10_000,
        gifFrameMaxLongEdge: 1280
    )
}
