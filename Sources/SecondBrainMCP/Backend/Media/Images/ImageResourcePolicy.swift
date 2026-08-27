import Foundation

/// Single backend authority for image dimension safety.
///
/// Both external image imports and vault image reads inspect metadata before
/// decoding pixels. Routing that inspection through this policy keeps the
/// decode-bomb limit and its diagnostic identical across both workflows.
enum ImageResourcePolicy {
    /// Invalid or unsafe pixel geometry reported by an image encoder.
    enum ValidationError: Error, CustomStringConvertible, CallerSafeError, Sendable {
        /// Width or height is zero or negative.
        case invalidDimensions(width: Int, height: Int)
        /// The decoded pixel count exceeds the configured resource limit.
        case tooManyPixels(megapixels: Double, limit: Double)
        /// The animation reports an invalid frame count.
        case invalidFrameCount(Int)
        /// The animation exceeds the configured metadata frame ceiling.
        case tooManyAnimationFrames(count: Int, limit: Int)

        /// Only numeric geometry and fixed policy text cross the tool boundary.
        var callerSafeDescription: String { description }

        /// Human-readable image geometry failure.
        var description: String {
            switch self {
            case .invalidDimensions(let width, let height):
                return "Image dimensions must be positive: \(width)x\(height)"
            case .tooManyPixels(let megapixels, let limit):
                return "Image has too many pixels: \(String(format: "%.1f", megapixels)) MP "
                    + "(limit \(String(format: "%.0f", limit)) MP)"
            case .invalidFrameCount(let count):
                return "Image frame count must be positive: \(count)"
            case .tooManyAnimationFrames(let count, let limit):
                return "Animated image has too many frames: \(count) (limit \(limit))"
            }
        }
    }

    /// Validates inspected dimensions before any pixel decoding occurs.
    ///
    /// - Parameters:
    ///   - inspection: Image metadata read without decoding pixel buffers.
    ///   - maximumMegapixels: Maximum permitted width-times-height in megapixels.
    ///   - maximumAnimationFrames: Maximum source GIF frames accepted for inspection.
    /// - Throws: ``ValidationError`` when dimensions are invalid or exceed the limit.
    static func validate(
        _ inspection: ImageInspection,
        maximumMegapixels: Double,
        maximumAnimationFrames: Int = .max
    ) throws {
        guard inspection.pixelWidth > 0, inspection.pixelHeight > 0 else {
            throw ValidationError.invalidDimensions(
                width: inspection.pixelWidth,
                height: inspection.pixelHeight
            )
        }
        let megapixels = Double(inspection.pixelWidth)
            * Double(inspection.pixelHeight)
            / 1_000_000
        guard megapixels <= maximumMegapixels else {
            throw ValidationError.tooManyPixels(
                megapixels: megapixels,
                limit: maximumMegapixels
            )
        }
        guard inspection.frameCount > 0 else {
            throw ValidationError.invalidFrameCount(inspection.frameCount)
        }
        if inspection.format.lowercased() == "gif",
           inspection.frameCount > max(maximumAnimationFrames, 0) {
            throw ValidationError.tooManyAnimationFrames(
                count: inspection.frameCount,
                limit: max(maximumAnimationFrames, 0)
            )
        }
    }
}
