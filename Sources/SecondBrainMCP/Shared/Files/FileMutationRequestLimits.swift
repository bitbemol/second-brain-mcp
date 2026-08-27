/// Transport-neutral limits for caller-controlled mutation metadata.
///
/// Both the public schema and backend preflight derive from these constants so
/// large metadata cannot consume unbounded work before file-content validation.
enum FileMutationRequestLimits {
    /// Maximum number of exact replacements in one update request.
    static let maximumReplacements = 20
    /// Maximum number of Markdown tags accepted by one creation request.
    static let maximumTagCount = 100
    /// Maximum UTF-8 bytes accepted for one Markdown tag.
    static let maximumTagBytes = 4 * 1024
    /// Maximum aggregate UTF-8 bytes accepted across all Markdown tags.
    static let maximumAggregateTagBytes = 64 * 1024
    /// Maximum UTF-8 bytes accepted for an external media source path.
    static let maximumSourcePathBytes = 4 * 1024
}
