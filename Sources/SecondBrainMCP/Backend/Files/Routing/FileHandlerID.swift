/// Stable diagnostic identities for reusable format handlers.
///
/// These values describe the resolver selected by the catalog. They are written
/// to the audit log but never exposed as API contracts.
enum FileHandlerID: String, Sendable {
    /// Markdown preparation and reading.
    case markdown
    /// JSON Canvas validation and summarization.
    case canvas
    /// HTTP Archive validation and summarization.
    case har
    /// Unified diff validation and summarization.
    case patch
    /// UTF-8 log preparation and bounded reading.
    case log
    /// General JSON validation and lossless reading.
    case json
    /// CSV validation and lossless reading.
    case csv
    /// External image normalization and image reading.
    case image
    /// External video conversion to animated GIF.
    case videoToGIF = "video_to_gif"
    /// PDF extraction and page rendering.
    case pdf
    /// Recoverable movement into `.trash/`.
    case softDelete = "soft_delete"
}
