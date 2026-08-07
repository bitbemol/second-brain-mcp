import Foundation

/// Mutable counters shared across every fuzzy comparison in one request.
struct SearchWorkBudget: Sendable {
    var tokenComparisons = 0
    var fuzzyComparisons = 0
    var editDistanceCells = 0
    var exhausted = false
    var truncated = false
}

/// One field-level match. Quality is an internal ranking value, not a probability.
struct SearchMatch: Sendable {
    let quality: Double
    let range: Range<String.Index>?
}

/// Literal, lexical, and bounded typo-tolerant matching primitives.
enum SearchTextMatcher {
    static func match(
        text: String,
        query: String,
        queryTokens: [SearchToken],
        strategy: SearchStrategy,
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> SearchMatch? {
        switch strategy {
        case .exact:
            return exact(text: text, query: query)
        case .phrase, .lexical, .fuzzy, .smart:
            if let exact = exact(text: text, query: query) { return exact }
            let tokenization = try SearchTokenizer.boundedTokens(
                in: text,
                maximumTokens: limits.maximumSourceTokensPerField,
                maximumTokenScalars: limits.maximumTokenScalars
            )
            if tokenization.truncated { budget.truncated = true }
            let sourceTokens = tokenization.tokens

            if strategy == .phrase {
                return try phrase(
                    sourceTokens: sourceTokens,
                    queryTokens: queryTokens,
                    budget: &budget,
                    limits: limits
                )
            }
            if strategy == .lexical {
                return try lexical(
                    sourceTokens: sourceTokens,
                    queryTokens: queryTokens,
                    budget: &budget,
                    limits: limits
                )
            }
            if strategy == .fuzzy {
                return try fuzzy(
                    text: text,
                    sourceTokens: sourceTokens,
                    queryTokens: queryTokens,
                    budget: &budget,
                    limits: limits
                )
            }

            if let phrase = try phrase(
                sourceTokens: sourceTokens,
                queryTokens: queryTokens,
                budget: &budget,
                limits: limits
            ) {
                return phrase
            }
            let lexical = try lexical(
                sourceTokens: sourceTokens,
                queryTokens: queryTokens,
                budget: &budget,
                limits: limits
            )
            if lexical?.quality == 70 { return lexical }
            let fuzzy = try fuzzy(
                text: text,
                sourceTokens: sourceTokens,
                queryTokens: queryTokens,
                budget: &budget,
                limits: limits
            )
            switch (lexical, fuzzy) {
            case (.some(let lexical), .some(let fuzzy)):
                return lexical.quality >= fuzzy.quality ? lexical : fuzzy
            case (.some(let lexical), .none):
                return lexical
            case (.none, .some(let fuzzy)):
                return fuzzy
            case (.none, .none):
                return nil
            }
        }
    }

    private static func exact(text: String, query: String) -> SearchMatch? {
        guard let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return nil }
        return SearchMatch(quality: 100, range: range)
    }

    private static func phrase(
        sourceTokens: [SearchToken],
        queryTokens: [SearchToken],
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> SearchMatch? {
        let required = queryTokens.map(\.normalized)
        guard !required.isEmpty else { return nil }
        guard sourceTokens.count >= required.count else { return nil }

        for start in 0...(sourceTokens.count - required.count) {
            var matches = true
            for offset in required.indices {
                guard try consumeComparison(&budget, limits: limits) else {
                    return nil
                }
                if sourceTokens[start + offset].normalized != required[offset] {
                    matches = false
                    break
                }
            }
            if matches {
                return SearchMatch(
                    quality: 80,
                    range: sourceTokens[start].range.lowerBound..<sourceTokens[
                        start + required.count - 1
                    ].range.upperBound
                )
            }
        }
        return nil
    }

    private static func lexical(
        sourceTokens: [SearchToken],
        queryTokens: [SearchToken],
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> SearchMatch? {
        let required = uniqueTerms(queryTokens)
        guard !required.isEmpty else { return nil }
        var firstRangeByTerm: [String: Range<String.Index>] = [:]
        let requiredSet = Set(required)
        for token in sourceTokens {
            guard try consumeComparison(&budget, limits: limits) else { return nil }
            guard requiredSet.contains(token.normalized) else { continue }
            if firstRangeByTerm[token.normalized] == nil {
                firstRangeByTerm[token.normalized] = token.range
            }
        }
        guard !firstRangeByTerm.isEmpty else { return nil }

        let coverage = Double(firstRangeByTerm.count) / Double(required.count)
        let allTermsBonus = firstRangeByTerm.count == required.count ? 10.0 : 0.0
        return SearchMatch(
            quality: 30 + (30 * coverage) + allTermsBonus,
            range: firstRangeByTerm.values.min { $0.lowerBound < $1.lowerBound }
        )
    }

    private static func fuzzy(
        text: String,
        sourceTokens: [SearchToken],
        queryTokens: [SearchToken],
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> SearchMatch? {
        let required = uniqueTerms(queryTokens)
        guard !required.isEmpty else { return nil }
        let source = sourceTokens.filter {
            $0.normalized.unicodeScalars.count <= limits.maximumTokenScalars
        }
        let exactLookup = Dictionary(grouping: source.indices, by: {
            source[$0].normalized
        })
        var consumedIndices = Set<Int>()
        var ranges: [Range<String.Index>] = []
        var exactCount = 0

        for term in required {
            try Task.checkCancellation()
            if let exactIndex = exactLookup[term]?.first(where: {
                !consumedIndices.contains($0)
            }) {
                let exact = source[exactIndex]
                consumedIndices.insert(exactIndex)
                exactCount += 1
                ranges.append(exact.range)
                continue
            }

            let length = term.unicodeScalars.count
            guard length >= 3 else { return nil }
            let maximumDistance = length <= 7 ? 1 : 2
            var best: (distance: Int, index: Int, range: Range<String.Index>)?

            for (index, candidate) in source.enumerated() {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                guard !budget.exhausted else { return nil }
                guard !consumedIndices.contains(index) else { continue }
                guard try consumeComparison(&budget, limits: limits) else {
                    return nil
                }
                let candidateLength = candidate.normalized.unicodeScalars.count
                guard abs(candidateLength - length) <= maximumDistance else {
                    continue
                }
                budget.fuzzyComparisons += 1
                if budget.fuzzyComparisons > limits.maximumFuzzyComparisons {
                    budget.exhausted = true
                    return nil
                }
                if let distance = boundedEditDistance(
                    term,
                    candidate.normalized,
                    maximum: maximumDistance,
                    budget: &budget,
                    limits: limits
                ), best == nil || distance < best!.distance {
                    best = (distance, index, candidate.range)
                    if distance == 0 { break }
                }
            }
            guard let best else { return nil }
            consumedIndices.insert(best.index)
            ranges.append(best.range)
        }

        let exactFraction = Double(exactCount) / Double(required.count)
        return SearchMatch(
            quality: 48 + (12 * exactFraction),
            range: earliestRange(ranges, in: text)
        )
    }

    private static func consumeComparison(
        _ budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> Bool {
        budget.tokenComparisons += 1
        if budget.tokenComparisons.isMultiple(of: 1_024) {
            try Task.checkCancellation()
        }
        guard budget.tokenComparisons <= limits.maximumTokenComparisons else {
            budget.exhausted = true
            return false
        }
        return true
    }

    private static func boundedEditDistance(
        _ lhs: String,
        _ rhs: String,
        maximum: Int,
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) -> Int? {
        let left = lhs.unicodeScalars.map(\.value)
        let right = rhs.unicodeScalars.map(\.value)
        guard abs(left.count - right.count) <= maximum else { return nil }

        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            var rowMinimum = current[0]
            for rightIndex in right.indices {
                budget.editDistanceCells += 1
                if budget.editDistanceCells > limits.maximumEditDistanceCells {
                    budget.exhausted = true
                    return nil
                }
                let substitution = previous[rightIndex]
                    + (left[leftIndex] == right[rightIndex] ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
                rowMinimum = min(rowMinimum, current[rightIndex + 1])
            }
            guard rowMinimum <= maximum else { return nil }
            previous = current
        }
        let distance = previous[right.count]
        return distance <= maximum ? distance : nil
    }

    private static func uniqueTerms(_ tokens: [SearchToken]) -> [String] {
        var seen = Set<String>()
        return tokens.compactMap { token in
            seen.insert(token.normalized).inserted ? token.normalized : nil
        }
    }

    private static func earliestRange(
        _ ranges: [Range<String.Index>],
        in text: String
    ) -> Range<String.Index>? {
        ranges.min {
            text.distance(from: text.startIndex, to: $0.lowerBound)
                < text.distance(from: text.startIndex, to: $1.lowerBound)
        }
    }
}

/// Builds a bounded plain-text excerpt without interpreting vault markup.
enum SearchSnippetBuilder {
    static func make(
        from text: String,
        around range: Range<String.Index>?,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> String {
        guard maximumCharacters > 0, maximumBytes > 0, !text.isEmpty else {
            return ""
        }
        let center = range?.lowerBound ?? text.startIndex
        let before = maximumCharacters / 3
        let start = text.index(
            center,
            offsetBy: -before,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            start,
            offsetBy: maximumCharacters,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        var excerpt = String(text[start..<end])
        excerpt = excerpt.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\r" { return " / " }
            if scalar == "\t" { return " " }
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar) {
                return ""
            }
            return String(scalar)
        }.joined()
        excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { excerpt = "…" + excerpt }
        if end < text.endIndex { excerpt += "…" }
        while excerpt.utf8.count > maximumBytes, !excerpt.isEmpty {
            excerpt.removeLast()
        }
        return excerpt
    }
}
