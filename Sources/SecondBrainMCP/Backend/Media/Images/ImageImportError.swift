/// Failures raised while validating or normalizing an external image.
enum ImageImportError: Error, CustomStringConvertible, CallerSafeError, Sendable {
    /// The source cannot be inspected or decoded as an image.
    case notAnImage(String)
    /// The detected image format is not in the supported format set.
    case unsupportedFormat(String)

    /// Paths and detected format strings are internal diagnostics, not caller output.
    var callerSafeDescription: String {
        switch self {
        case .notAnImage:
            "Source is not a readable image; choose a valid supported image file outside the vault."
        case .unsupportedFormat:
            "Unsupported image format; use PNG, JPEG, GIF, WebP, HEIC, TIFF, or BMP."
        }
    }

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
