import Foundation

/// One immutable file projection consumed by the search engine.
struct SearchDocument: Sendable {
    let path: String
    let format: FileFormat
    let title: String
    let tags: [String]
    let sections: [SearchSection]
}

/// One format-aware section with stable source-line coordinates.
struct SearchSection: Sendable {
    let heading: String?
    let location: VaultSearchLocation?
    let content: String
    let lineStart: Int
    let lineEnd: Int
}

/// Corpus construction facts that remain independent from ranking strategy.
struct SearchCorpus: Sendable {
    let documents: [SearchDocument]
    let skippedFileCount: Int
    let skippedSensitiveFileCount: Int
    let resourceLimitedFileCount: Int
    let partiallyLimitedPaths: Set<String>
    let resourceLimitSamples: [VaultSearchResourceLimit]
    let coverageIncomplete: Bool
}

/// Builds non-sensitive, deterministic resource diagnostics without retaining
/// an unbounded list of omitted paths.
enum SearchResourceDiagnostics {
    static func sample(
        path: String,
        reason: VaultSearchResourceLimitReason,
        impact: VaultSearchResourceLimitImpact
    ) throws -> VaultSearchResourceLimit? {
        try Task.checkCancellation()
        guard path.utf8.count <= SearchRequestLimits.maximumDiagnosticPathBytes else {
            return nil
        }
        do {
            try SensitiveContentPolicy.validate(
                Data(path.utf8),
                format: .markdown,
                path: "search diagnostic path"
            )
            return VaultSearchResourceLimit(path: path, reason: reason, impact: impact)
        } catch is SensitiveContentPolicy.Violation {
            return nil
        }
    }

    static func merged(
        _ groups: [VaultSearchResourceLimit]...
    ) -> [VaultSearchResourceLimit] {
        var byPath: [String: VaultSearchResourceLimit] = [:]
        for diagnostic in groups.flatMap({ $0 }) {
            if let existing = byPath[diagnostic.path] {
                let existingPriority = priority(existing)
                if priority(diagnostic) < existingPriority {
                    byPath[diagnostic.path] = diagnostic
                }
            } else {
                byPath[diagnostic.path] = diagnostic
            }
        }
        return Array(byPath.values)
            .sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                if $0.reason.rawValue != $1.reason.rawValue {
                    return $0.reason.rawValue < $1.reason.rawValue
                }
                return $0.impact.rawValue < $1.impact.rawValue
            }
            .prefix(SearchRequestLimits.maximumResourceLimitSamples)
            .map { $0 }
    }

    private static func priority(_ diagnostic: VaultSearchResourceLimit) -> String {
        let impact = diagnostic.impact == .omitted ? "0" : "1"
        return impact + diagnostic.reason.rawValue
    }
}

/// A query or corpus token whose range always belongs to its original string.
struct SearchToken: Sendable {
    let normalized: String
    let range: Range<String.Index>
}

/// A bounded token projection and whether later source text was omitted.
struct SearchTokenization: Sendable {
    let tokens: [SearchToken]
    let truncated: Bool
}

/// Tokenization that never reuses indices from folded text against source text.
enum SearchTokenizer {
    private static let tokenScalars = CharacterSet.letters
        .union(.decimalDigits)
        .union(.nonBaseCharacters)

    static func tokens(in text: String) -> [SearchToken] {
        var tokens: [SearchToken] = []
        var start: String.Index?
        var index = text.startIndex

        func finish(at end: String.Index) {
            guard let tokenStart = start else { return }
            let source = String(text[tokenStart..<end])
            tokens.append(SearchToken(
                normalized: normalize(source),
                range: tokenStart..<end
            ))
            start = nil
        }

        while index < text.endIndex {
            let character = text[index]
            let isToken = character.unicodeScalars.allSatisfy {
                tokenScalars.contains($0)
            }
            if isToken {
                if start == nil { start = index }
            } else {
                finish(at: index)
            }
            index = text.index(after: index)
        }
        finish(at: text.endIndex)
        return tokens.filter { !$0.normalized.isEmpty }
    }

    /// Tokenizes caller-independent corpus text without unbounded object growth.
    static func boundedTokens(
        in text: String,
        maximumTokens: Int,
        maximumTokenScalars: Int
    ) throws -> SearchTokenization {
        guard maximumTokens > 0, maximumTokenScalars > 0 else {
            return SearchTokenization(tokens: [], truncated: !text.isEmpty)
        }

        var tokens: [SearchToken] = []
        tokens.reserveCapacity(min(maximumTokens, 1_024))
        var start: String.Index?
        var scalarCount = 0
        var oversized = false
        var omitted = false
        var index = text.startIndex
        var visited = 0

        func finish(at end: String.Index) -> Bool {
            guard let tokenStart = start else { return true }
            defer {
                start = nil
                scalarCount = 0
                oversized = false
            }
            guard !oversized else {
                omitted = true
                return true
            }
            guard tokens.count < maximumTokens else { return false }
            let source = String(text[tokenStart..<end])
            let normalized = normalize(source)
            if !normalized.isEmpty {
                tokens.append(SearchToken(
                    normalized: normalized,
                    range: tokenStart..<end
                ))
            }
            return true
        }

        while index < text.endIndex {
            if visited.isMultiple(of: 1_024) { try Task.checkCancellation() }
            visited += 1
            let character = text[index]
            let isToken = character.unicodeScalars.allSatisfy {
                tokenScalars.contains($0)
            }
            if isToken {
                if start == nil { start = index }
                scalarCount += character.unicodeScalars.count
                if scalarCount > maximumTokenScalars { oversized = true }
            } else if !finish(at: index) {
                return SearchTokenization(tokens: tokens, truncated: true)
            }
            index = text.index(after: index)
        }
        guard finish(at: text.endIndex) else {
            return SearchTokenization(tokens: tokens, truncated: true)
        }
        return SearchTokenization(tokens: tokens, truncated: omitted)
    }

    static func normalize(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
