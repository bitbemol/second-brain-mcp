import Foundation

/// Validated input delivered to a stored-text create resolver.
///
/// The value deliberately excludes the caller's raw content and source path so
/// format handlers cannot bypass the centralized ingress policy.
struct TextFileCreateInput: Sendable {
    /// Size-bounded UTF-8 bytes ready for format-specific validation.
    let data: Data
    /// Optional note metadata used by formats such as Markdown.
    let tags: [String]
}
