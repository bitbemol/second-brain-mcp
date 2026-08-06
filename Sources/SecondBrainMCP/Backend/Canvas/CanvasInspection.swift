/// Validated canvas facts used to render a human-readable read summary.
///
/// This projection deliberately contains only presentation data. The original
/// JSON remains the persistence source so plugin-specific keys are never lost.
struct CanvasInspection: Equatable, Sendable {
    /// One validated canvas node prepared for summary rendering.
    struct Node: Equatable, Sendable {
        /// Concrete JSON Canvas node variants supported by the validator.
        enum Kind: String, Equatable, Sendable {
            /// Inline text node.
            case text
            /// Vault file reference node.
            case file
            /// External URL node.
            case link
            /// Visual grouping node.
            case group
        }

        /// Stable canvas node identifier.
        let id: String
        /// Validated concrete node variant.
        let kind: Kind
        /// Short text, path, URL, or group label displayed in summaries.
        let label: String
        /// Referenced vault path for file nodes; `nil` for every other kind.
        let filePath: String?
    }

    /// Validated nodes in their source order.
    let nodes: [Node]
    /// Number of validated edges in the canvas.
    let edgeCount: Int
}
