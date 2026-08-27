import Foundation

/// Failures raised while validating or converting an external video.
enum VideoImportError: Error, CustomStringConvertible, CallerSafeError {
    /// The source has no readable video track or usable duration.
    case notAVideo(String)
    /// The source duration exceeds the configured conversion limit.
    case durationTooLong(seconds: Double, limit: Double)
    /// The encoded GIF exceeds the configured output limit.
    case outputTooLarge(bytes: Int, limit: Int)
    /// The platform encoder failed while producing the GIF.
    case conversionFailed(String)

    /// Exposes corrective rules and numeric bounds, never source paths or framework details.
    var callerSafeDescription: String {
        switch self {
        case .notAVideo:
            return "Source is not a readable video; choose a valid video file with a video track outside the vault."
        case .durationTooLong(let seconds, let limit):
            return "Video is too long: \(String(format: "%.0f", seconds))s "
                + "(limit \(String(format: "%.0f", limit))s); choose a shorter clip."
        case .outputTooLarge(let bytes, let limit):
            return "Resulting GIF is too large: \(bytes) bytes (limit \(limit)); choose a shorter clip."
        case .conversionFailed:
            return "Video conversion failed; check that the source video is playable or choose another clip."
        }
    }

    /// Human-readable external-video import failure.
    var description: String {
        switch self {
        case .notAVideo(let path):
            return "Source is not a readable video: \(path)"
        case .durationTooLong(let seconds, let limit):
            return "Video is too long: \(String(format: "%.0f", seconds))s "
                + "(limit \(String(format: "%.0f", limit))s)"
        case .outputTooLarge(let bytes, let limit):
            return "Resulting GIF is too large: \(bytes) bytes (limit \(limit)) "
                + "— try a shorter clip or lower fidelity"
        case .conversionFailed(let reason):
            return "Video conversion failed: \(reason)"
        }
    }
}
