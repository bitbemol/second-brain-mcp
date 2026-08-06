/// Positive integer display dimensions derived safely from video metadata.
struct VideoPixelDimensions: Equatable, Sendable {
    /// Rounded display width in pixels.
    let width: Int
    /// Rounded display height in pixels.
    let height: Int

    /// Converts potentially malformed floating-point track geometry.
    ///
    /// Negative values are normalized because rotation transforms can reverse an
    /// axis. Zero, non-finite, and values outside Swift's integer range are rejected
    /// before `Int` conversion can trap the process.
    ///
    /// - Parameters:
    ///   - width: Display-space width reported by the media framework.
    ///   - height: Display-space height reported by the media framework.
    init?(width: Double, height: Double) {
        guard let width = Self.pixelValue(width),
              let height = Self.pixelValue(height) else {
            return nil
        }
        self.width = width
        self.height = height
    }

    private static func pixelValue(_ value: Double) -> Int? {
        let rounded = abs(value).rounded()
        guard rounded.isFinite,
              rounded > 0,
              rounded < Double(Int.max) else {
            return nil
        }
        return Int(rounded)
    }
}
