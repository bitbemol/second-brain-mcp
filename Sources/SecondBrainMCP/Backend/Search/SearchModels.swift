import Foundation

/// One immutable file projection consumed by the search engine.
struct SearchDocument: Sendable {
    let path: String
    let format: FileFormat
    let title: String
    let tags: [String]
    let sections: [SearchSection]
    let pdfTextExtractionStatus: PDFTextExtractionStatus?

    init(
        path: String,
        format: FileFormat,
        title: String,
        tags: [String],
        sections: [SearchSection],
        pdfTextExtractionStatus: PDFTextExtractionStatus? = nil
    ) {
        self.path = path
        self.format = format
        self.title = title
        self.tags = tags
        self.sections = sections
        self.pdfTextExtractionStatus = pdfTextExtractionStatus
    }
}

/// One format-aware section with stable source-line coordinates.
struct SearchSection: Sendable {
    let heading: String?
    let location: VaultSearchLocation?
    let content: String
    let lineStart: Int
    let lineEnd: Int
    let physicalPage: Int?
    let printedPage: String?
    let pdfPageKind: PDFSearchPageKind?

    init(
        heading: String?,
        location: VaultSearchLocation?,
        content: String,
        lineStart: Int,
        lineEnd: Int,
        physicalPage: Int? = nil,
        printedPage: String? = nil,
        pdfPageKind: PDFSearchPageKind? = nil
    ) {
        self.heading = heading
        self.location = location
        self.content = content
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.physicalPage = physicalPage
        self.printedPage = printedPage
        self.pdfPageKind = pdfPageKind
    }
}

/// Corpus construction facts that remain independent from ranking strategy.
struct SearchCorpus: Sendable {
    let documents: [SearchDocument]
    /// Exact-byte identity of every admitted snapshot and candidate shape.
    let revisionFingerprint: String
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

/// Space-delimited normalized terms produced without retaining source ranges.
struct SearchNormalizedTermProjection: Sendable {
    let value: String
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
            for range in identifierComponentRanges(
                in: text,
                range: tokenStart..<end
            ) {
                let normalized = normalize(String(text[range]))
                if !normalized.isEmpty {
                    tokens.append(SearchToken(normalized: normalized, range: range))
                }
            }
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
            for range in identifierComponentRanges(
                in: text,
                range: tokenStart..<end
            ) {
                guard tokens.count < maximumTokens else { return false }
                let normalized = normalize(String(text[range]))
                if !normalized.isEmpty {
                    tokens.append(SearchToken(normalized: normalized, range: range))
                }
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

    /// Produces the same normalized identifier components as `boundedTokens`
    /// without allocating one range-bearing object per corpus token.
    static func boundedNormalizedTerms(
        in text: String,
        maximumTokens: Int,
        maximumTokenScalars: Int,
        maximumBytes: Int
    ) throws -> SearchNormalizedTermProjection {
        guard maximumTokens > 0, maximumTokenScalars > 0, maximumBytes > 0 else {
            return SearchNormalizedTermProjection(
                value: "",
                truncated: !text.isEmpty
            )
        }

        var result = ""
        result.reserveCapacity(min(text.utf8.count, maximumBytes))
        var resultBytes = 0
        var tokenCount = 0
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
            for range in identifierComponentRanges(
                in: text,
                range: tokenStart..<end
            ) {
                guard tokenCount < maximumTokens else { return false }
                let normalized = normalize(String(text[range]))
                guard !normalized.isEmpty else { continue }
                let separatorBytes = result.isEmpty ? 0 : 1
                let addedBytes = separatorBytes + normalized.utf8.count
                guard addedBytes <= maximumBytes - resultBytes else {
                    return false
                }
                if separatorBytes > 0 { result.append(" ") }
                result.append(normalized)
                resultBytes += addedBytes
                tokenCount += 1
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
                return SearchNormalizedTermProjection(
                    value: result,
                    truncated: true
                )
            }
            index = text.index(after: index)
        }
        guard finish(at: text.endIndex) else {
            return SearchNormalizedTermProjection(value: result, truncated: true)
        }
        return SearchNormalizedTermProjection(value: result, truncated: omitted)
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return englishSearchRoot(folded)
    }

    /// Splits identifiers at lower-to-upper, acronym-to-word, and digit
    /// boundaries while preserving ranges into the original source string.
    private static func identifierComponentRanges(
        in text: String,
        range: Range<String.Index>
    ) -> [Range<String.Index>] {
        let indices = Array(text.indices[range])
        guard indices.count > 1 else { return [range] }
        var boundaries = [range.lowerBound]
        for offset in 1..<indices.count {
            let previous = text[indices[offset - 1]]
            let current = text[indices[offset]]
            let next = offset + 1 < indices.count ? text[indices[offset + 1]] : nil
            let lowerToUpper = previous.isLowercase && current.isUppercase
            let acronymToWord = previous.isUppercase && current.isUppercase
                && next?.isLowercase == true
            let digitBoundary = previous.isNumber != current.isNumber
                && (previous.isLetter || previous.isNumber)
                && (current.isLetter || current.isNumber)
            if lowerToUpper || acronymToWord || digitBoundary {
                boundaries.append(indices[offset])
            }
        }
        boundaries.append(range.upperBound)
        return zip(boundaries, boundaries.dropFirst()).map { $0..<$1 }
    }

    /// Conservative inflection folding used only by word-oriented strategies.
    private static func englishSearchRoot(_ value: String) -> String {
        guard value.unicodeScalars.allSatisfy({
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }) else { return value }
        guard value.count > 3 else { return value }
        if value.hasSuffix("ies"), value.count > 4 {
            return String(value.dropLast(3)) + "y"
        }
        if value.hasSuffix("ing"), value.count > 5 {
            var root = String(value.dropLast(3))
            if root.count > 2, root.last == root.dropLast().last {
                root.removeLast()
            }
            return root
        }
        if value.hasSuffix("ed"), value.count > 4 {
            return String(value.dropLast(2))
        }
        if value.hasSuffix("s"),
           !value.hasSuffix("ss"),
           !value.hasSuffix("us"),
           !value.hasSuffix("is") {
            return String(value.dropLast())
        }
        return value
    }
}

/// Extracts the high-information terms used by conversational smart search.
enum SearchQueryAnalyzer {
    private static let stopWords: Set<String> = Set([
        "a", "about", "after", "an", "and", "are", "as", "at", "be",
        "behind", "by", "can", "could", "did", "do", "does", "for", "from",
        "how", "i", "in", "into", "is", "it", "look", "me", "my", "of",
        "on", "or", "please", "should", "show", "that", "the", "their",
        "this", "to", "was", "were", "what", "when", "where", "which",
        "who", "why", "with", "would", "you",
    ].map(SearchTokenizer.normalize))

    private static let intentWords: Set<String> = Set([
        "avoid", "explain", "find", "help", "prevent", "tell", "want",
    ].map(SearchTokenizer.normalize))

    static func significantTokens(in query: String) -> [SearchToken] {
        let all = SearchTokenizer.tokens(in: query)
        let significant = all.filter {
            !stopWords.contains($0.normalized) && !intentWords.contains($0.normalized)
        }
        return significant.isEmpty ? all : significant
    }

    static func containsSymbolSyntax(_ query: String) -> Bool {
        // Natural-language punctuation must not turn an otherwise conversational
        // smart query into literal-only code search. Strong code/path sigils are
        // protected only when the complete query is one compact expression;
        // callers can always select `.exact` for a longer literal expression.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return false }
        let strongSymbols = CharacterSet(charactersIn: "@#$%^&*+=<>/\\|[]{}\u{0060}")
        if trimmed.unicodeScalars.contains(where: strongSymbols.contains) {
            return true
        }
        // A compact dotted identifier or hidden/path-like name is code-shaped;
        // ordinary sentence-final periods are not because they include spaces.
        return trimmed.dropFirst().dropLast().contains(".")
            || trimmed.hasPrefix(".")
    }
}
