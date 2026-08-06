import Foundation

/// Pure detector for explicit parent-directory components in untrusted paths.
enum PathTraversalDetector {
    /// Defensive nesting limit that prevents adversarial inputs from causing
    /// unbounded repeated string decoding.
    private static let maximumPercentDecodingPasses = 8

    /// Checks raw, Unicode-normalized, and repeatedly percent-decoded path forms.
    ///
    /// Repeated decoding prevents nested encodings such as `%252e%252e` from
    /// hiding a `..` component. Up to eight layers are inspected; decoding stops
    /// earlier when the value no longer changes or contains malformed escapes.
    ///
    /// - Parameter path: Caller-controlled relative or canonical path text.
    /// - Returns: `true` when any decoded form contains a parent component.
    static func containsTraversal(in path: String) -> Bool {
        var candidate = path
        var decodingPasses = 0

        while true {
            let normalized = candidate.precomposedStringWithCanonicalMapping
            if containsParentComponent(in: normalized) {
                return true
            }

            guard decodingPasses < maximumPercentDecodingPasses,
                  let decoded = candidate.removingPercentEncoding,
                  decoded != candidate else {
                return false
            }
            candidate = decoded
            decodingPasses += 1
        }
    }

    private static func containsParentComponent(in path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .contains { component in
                component.trimmingCharacters(in: .whitespaces) == ".."
            }
    }
}
