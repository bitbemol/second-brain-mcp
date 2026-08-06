/// Converts Swift decoding failures into concise JSON Canvas diagnostics.
enum CanvasDecodingErrorFormatter {
    /// Describes a decoding failure with its JSON coding path when available.
    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing field '\(key.stringValue)'\(location(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(context.debugDescription)\(location(context))"
        case .dataCorrupted(let context):
            return context.debugDescription.isEmpty
                ? "malformed JSON"
                : "\(context.debugDescription)\(location(context))"
        @unknown default:
            return "invalid structure"
        }
    }

    /// Formats a non-empty coding path for a human-readable diagnostic.
    private static func location(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }
        return path.isEmpty ? "" : " (at \(path.joined(separator: " → ")))"
    }
}
