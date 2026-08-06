/// Failures raised while validating or normalizing an external image.
enum ImageImportError: Error, CustomStringConvertible, Sendable {
    /// The source cannot be inspected or decoded as an image.
    case notAnImage(String)
    /// The detected image format is not in the supported format set.
    case unsupportedFormat(String)

    /// Human-readable external-image import failure.
    var description: String {
        switch self {
        case .notAnImage(let path):
            return "Source is not a readable image: \(path)"
        case .unsupportedFormat(let format):
            return "Unsupported image format: \(format)"
        }
    }
}
