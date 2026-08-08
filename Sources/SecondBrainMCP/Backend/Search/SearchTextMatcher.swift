import Foundation

/// Mutable counters shared across every fuzzy comparison in one request.
struct SearchWorkBudget: Sendable {
    var tokenComparisons = 0
    var fuzzyComparisons = 0
    var editDistanceCells = 0
    var literalOccurrences = 0
    var exhausted = false
    var truncated = false
    let maximumTokenComparisons: Int
    let maximumFuzzyComparisons: Int
    let maximumEditDistanceCells: Int
    let maximumLiteralOccurrences: Int

    init(
        maximumTokenComparisons: Int = .max,
        maximumFuzzyComparisons: Int = .max,
        maximumEditDistanceCells: Int = .max,
        maximumLiteralOccurrences: Int = .max
    ) {
        self.maximumTokenComparisons = maximumTokenComparisons
        self.maximumFuzzyComparisons = maximumFuzzyComparisons
        self.maximumEditDistanceCells = maximumEditDistanceCells
        self.maximumLiteralOccurrences = maximumLiteralOccurrences
        self.exhausted = maximumTokenComparisons <= 0
            || maximumLiteralOccurrences <= 0
    }
}

/// One field-level match. Quality is an internal ranking value, not a probability.
enum SearchMatchKind: Equatable, Sendable {
    /// Literal occurrence bounded by token edges.
    case literalWhole
    /// Literal occurrence embedded inside a larger token.
    case literalSubstring
    /// Adjacent ordered normalized terms.
    case phrase
    /// One or more exact normalized terms in any order.
    case lexical
    /// Bounded edit-distance evidence.
    case fuzzy
}

/// Evidence contributed by one searchable field.
struct SearchMatch: Sendable {
    /// Internal ordering weight.
    let quality: Double
    /// Normalized evidence strength used by public relevance.
    let strength: Double
    /// Source range used to center a snippet.
    let range: Range<String.Index>?
    /// Unique normalized query terms covered by this field.
    let coveredTerms: Set<String>
    /// Whether this field alone satisfies the complete query.
    let completeQuery: Bool
    /// Concrete matching behavior that produced the evidence.
    let kind: SearchMatchKind
}

/// Literal, lexical, and bounded typo-tolerant matching primitives.
enum SearchTextMatcher {
    private struct FuzzyOption {
        let sourceIndex: Int
        let distance: Int
        let maximumDistance: Int
        let range: Range<String.Index>
    }

    static func match(
        text: String,
        query: String,
        queryTokens: [SearchToken],
        strategy: SearchStrategy,
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits,
        allowsExact: Bool = true,
        allowsPartialFuzzy: Bool = false
    ) throws -> SearchMatch? {
        switch strategy {
        case .exact:
            return try exact(
                text: text,
                query: query,
                queryTokens: queryTokens,
                budget: &budget,
                limits: limits
            )
        case .phrase, .lexical, .fuzzy, .smart:
            let symbolQuery = SearchQueryAnalyzer.containsSymbolSyntax(query)
            let checksLiteral = allowsExact && (strategy == .smart || symbolQuery)
            let literal = checksLiteral
                ? try exact(
                    text: text,
                    query: query,
                    queryTokens: queryTokens,
                    budget: &budget,
                    limits: limits
                ) : nil
            if strategy == .smart, literal?.kind == .literalWhole {
                return literal
            }
            if symbolQuery {
                return literal?.kind == .literalWhole ? literal : nil
            }
            guard !budget.exhausted else { return nil }
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
                    limits: limits,
                    allowsPartial: allowsPartialFuzzy
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
                limits: limits,
                allowsPartial: allowsPartialFuzzy
            )
            switch (lexical, fuzzy) {
            case (.some(let lexical), .some(let fuzzy)):
                if lexical.coveredTerms.count != fuzzy.coveredTerms.count {
                    return lexical.coveredTerms.count > fuzzy.coveredTerms.count
                        ? lexical : fuzzy
                }
                if lexical.strength != fuzzy.strength {
                    return lexical.strength > fuzzy.strength ? lexical : fuzzy
                }
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

    private static func exact(
        text: String,
        query: String,
        queryTokens: [SearchToken],
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> SearchMatch? {
        guard budget.literalOccurrences < budget.maximumLiteralOccurrences else {
            budget.exhausted = true
            budget.truncated = true
            return nil
        }
        let options: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]
        let locale = Locale(identifier: "en_US_POSIX")
        var firstRange: Range<String.Index>?
        var cursor = text.startIndex
        var wholeRange: Range<String.Index>?
        var observedOccurrences = 0
        while cursor < text.endIndex,
              let found = text.range(
                  of: query,
                  options: options,
                  range: cursor..<text.endIndex,
                  locale: locale
              ) {
            observedOccurrences += 1
            budget.literalOccurrences += 1
            if observedOccurrences.isMultiple(of: 1_024) {
                try Task.checkCancellation()
            }
            if firstRange == nil { firstRange = found }
            if hasTokenBoundaries(found, in: text) {
                wholeRange = found
                break
            }
            if observedOccurrences >= limits.maximumLiteralOccurrencesPerField
                || budget.literalOccurrences >= budget.maximumLiteralOccurrences {
                budget.truncated = true
                if budget.literalOccurrences >= budget.maximumLiteralOccurrences {
                    budget.exhausted = true
                }
                break
            }
            cursor = found.upperBound > found.lowerBound
                ? found.upperBound : text.index(after: found.lowerBound)
        }
        guard let range = wholeRange ?? firstRange else { return nil }
        let whole = wholeRange != nil
        return SearchMatch(
            quality: whole ? 100 : 42,
            strength: whole ? 1 : 0.45,
            range: range,
            coveredTerms: Set(queryTokens.map(\.normalized)),
            completeQuery: true,
            kind: whole ? .literalWhole : .literalSubstring
        )
    }

    private static func hasTokenBoundaries(
        _ range: Range<String.Index>,
        in text: String
    ) -> Bool {
        func isIdentifierCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
        let startsAtBoundary = range.lowerBound == text.startIndex
            || !isIdentifierCharacter(text[text.index(before: range.lowerBound)])
        let endsAtBoundary = range.upperBound == text.endIndex
            || !isIdentifierCharacter(text[range.upperBound])
        return startsAtBoundary && endsAtBoundary
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
                    strength: 0.95,
                    range: sourceTokens[start].range.lowerBound..<sourceTokens[
                        start + required.count - 1
                    ].range.upperBound,
                    coveredTerms: Set(required),
                    completeQuery: true,
                    kind: .phrase
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
                if firstRangeByTerm.count == required.count { break }
            }
        }
        guard !firstRangeByTerm.isEmpty else { return nil }

        let coverage = Double(firstRangeByTerm.count) / Double(required.count)
        let allTermsBonus = firstRangeByTerm.count == required.count ? 10.0 : 0.0
        return SearchMatch(
            quality: 30 + (30 * coverage) + allTermsBonus,
            strength: 0.85,
            range: firstRangeByTerm.values.min { $0.lowerBound < $1.lowerBound },
            coveredTerms: Set(firstRangeByTerm.keys),
            completeQuery: firstRangeByTerm.count == required.count,
            kind: .lexical
        )
    }

    private static func fuzzy(
        text: String,
        sourceTokens: [SearchToken],
        queryTokens: [SearchToken],
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits,
        allowsPartial: Bool
    ) throws -> SearchMatch? {
        let required = uniqueTerms(queryTokens)
        guard !required.isEmpty else { return nil }
        let source = sourceTokens.filter {
            $0.normalized.unicodeScalars.count <= limits.maximumTokenScalars
        }
        var optionsByTerm: [[FuzzyOption]] = []
        var matchedTerms: [String] = []
        optionsByTerm.reserveCapacity(required.count)
        let maximumOptionsPerTerm = max(required.count, 1)

        for term in required {
            try Task.checkCancellation()
            let length = term.unicodeScalars.count
            let maximumDistance = length < 3 ? 0 : (length <= 7 ? 1 : 2)
            var optionsByDistance = Array(
                repeating: [FuzzyOption](),
                count: maximumDistance + 1
            )

            func retain(_ option: FuzzyOption) {
                // At most `required.count` terms need distinct source tokens.
                // Retaining that many earliest candidates per cost tier
                // preserves full-match feasibility while bounding the graph.
                guard optionsByDistance[option.distance].count
                        < maximumOptionsPerTerm else { return }
                optionsByDistance[option.distance].append(option)
            }

            for (index, candidate) in source.enumerated() {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                guard !budget.exhausted else { return nil }
                guard try consumeComparison(&budget, limits: limits) else {
                    return nil
                }
                if candidate.normalized == term {
                    retain(FuzzyOption(
                        sourceIndex: index,
                        distance: 0,
                        maximumDistance: maximumDistance,
                        range: candidate.range
                    ))
                    continue
                }
                guard maximumDistance > 0 else { continue }
                let candidateLength = candidate.normalized.unicodeScalars.count
                guard abs(candidateLength - length) <= maximumDistance else {
                    continue
                }
                budget.fuzzyComparisons += 1
                let maximumFuzzy = min(
                    limits.maximumFuzzyComparisons,
                    budget.maximumFuzzyComparisons
                )
                if budget.fuzzyComparisons > maximumFuzzy {
                    budget.exhausted = true
                    return nil
                }
                if let distance = boundedEditDistance(
                    term,
                    candidate.normalized,
                    maximum: maximumDistance,
                    budget: &budget,
                    limits: limits
                ) {
                    retain(FuzzyOption(
                        sourceIndex: index,
                        distance: distance,
                        maximumDistance: maximumDistance,
                        range: candidate.range
                    ))
                }
                guard !budget.exhausted else { return nil }
            }
            let options = Array(
                optionsByDistance.joined().prefix(maximumOptionsPerTerm)
            )
            if options.isEmpty {
                guard allowsPartial else { return nil }
                continue
            }
            optionsByTerm.append(options)
            matchedTerms.append(term)
        }

        guard !optionsByTerm.isEmpty else { return nil }
        guard let chosen = try minimumCostAssignment(
            optionsByTerm,
            budget: &budget,
            limits: limits
        ) else { return nil }
        let exactCount = chosen.count { $0.distance == 0 }
        let totalDistance = chosen.map(\.distance).reduce(0, +)
        let totalAllowance = chosen.map(\.maximumDistance).reduce(0, +)
        let exactFraction = Double(exactCount) / Double(matchedTerms.count)
        let closeness = totalAllowance == 0
            ? 1.0
            : 1.0 - (Double(totalDistance) / Double(totalAllowance))
        return SearchMatch(
            quality: 48 + (10 * exactFraction) + (6 * max(closeness, 0)),
            strength: 0.60 + (0.20 * max(closeness, 0)),
            range: earliestRange(chosen.map(\.range), in: text),
            coveredTerms: Set(matchedTerms),
            completeQuery: matchedTerms.count == required.count,
            kind: .fuzzy
        )
    }

    /// Finds the highest-quality full distinct-token assignment.
    ///
    /// This is the rectangular Hungarian algorithm over a graph already
    /// bounded to at most queryTermCount² source positions. Missing term/token
    /// edges remain unavailable. Every matrix visit consumes the shared work
    /// budget, which also provides periodic cancellation checks.
    private static func minimumCostAssignment(
        _ optionsByTerm: [[FuzzyOption]],
        budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> [FuzzyOption]? {
        let rowCount = optionsByTerm.count
        guard rowCount > 0 else { return [] }
        let sourceIndices = Set(
            optionsByTerm.flatMap { $0.map(\.sourceIndex) }
        ).sorted()
        guard sourceIndices.count >= rowCount else { return nil }

        let totalAllowance = optionsByTerm.compactMap {
            $0.first?.maximumDistance
        }.reduce(0, +)
        let optionMaps = optionsByTerm.map { options in
            Dictionary(uniqueKeysWithValues: options.map {
                ($0.sourceIndex, $0)
            })
        }
        func cost(_ option: FuzzyOption) -> Int {
            let nonExact = option.distance == 0 ? 0 : 1
            return (10 * totalAllowance * nonExact)
                + (6 * option.distance * rowCount)
        }

        let columnCount = sourceIndices.count
        let infinity = Int.max / 4
        var rowPotential = Array(repeating: 0, count: rowCount + 1)
        var columnPotential = Array(repeating: 0, count: columnCount + 1)
        var columnOwner = Array(repeating: 0, count: columnCount + 1)
        var predecessor = Array(repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            columnOwner[0] = row
            var minimum = Array(repeating: infinity, count: columnCount + 1)
            var used = Array(repeating: false, count: columnCount + 1)
            var column = 0

            repeat {
                used[column] = true
                let activeRow = columnOwner[column]
                var delta = infinity
                var nextColumn = 0

                for candidateColumn in 1...columnCount where !used[candidateColumn] {
                    guard try consumeComparison(&budget, limits: limits) else {
                        return nil
                    }
                    let sourceIndex = sourceIndices[candidateColumn - 1]
                    if let option = optionMaps[activeRow - 1][sourceIndex] {
                        let reduced = cost(option)
                            - rowPotential[activeRow]
                            - columnPotential[candidateColumn]
                        if reduced < minimum[candidateColumn] {
                            minimum[candidateColumn] = reduced
                            predecessor[candidateColumn] = column
                        }
                    }
                    if minimum[candidateColumn] < delta {
                        delta = minimum[candidateColumn]
                        nextColumn = candidateColumn
                    }
                }
                guard nextColumn != 0, delta < infinity else { return nil }

                for candidateColumn in 0...columnCount {
                    if used[candidateColumn] {
                        rowPotential[columnOwner[candidateColumn]] += delta
                        columnPotential[candidateColumn] -= delta
                    } else if candidateColumn > 0,
                              minimum[candidateColumn] < infinity {
                        minimum[candidateColumn] -= delta
                    }
                }
                column = nextColumn
            } while columnOwner[column] != 0

            repeat {
                let previousColumn = predecessor[column]
                columnOwner[column] = columnOwner[previousColumn]
                column = previousColumn
            } while column != 0
        }

        var selected = Array<FuzzyOption?>(repeating: nil, count: rowCount)
        for column in 1...columnCount where columnOwner[column] > 0 {
            let row = columnOwner[column] - 1
            selected[row] = optionMaps[row][sourceIndices[column - 1]]
        }
        let result = selected.compactMap { $0 }
        return result.count == rowCount ? result : nil
    }

    private static func consumeComparison(
        _ budget: inout SearchWorkBudget,
        limits: SearchResourceLimits
    ) throws -> Bool {
        budget.tokenComparisons += 1
        if budget.tokenComparisons.isMultiple(of: 1_024) {
            try Task.checkCancellation()
        }
        let maximum = min(
            limits.maximumTokenComparisons,
            budget.maximumTokenComparisons
        )
        guard budget.tokenComparisons <= maximum else {
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

        var twoRowsBack: [Int]?
        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            var rowMinimum = current[0]
            for rightIndex in right.indices {
                budget.editDistanceCells += 1
                let maximumCells = min(
                    limits.maximumEditDistanceCells,
                    budget.maximumEditDistanceCells
                )
                if budget.editDistanceCells > maximumCells {
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
                if leftIndex > 0,
                   rightIndex > 0,
                   left[leftIndex] == right[rightIndex - 1],
                   left[leftIndex - 1] == right[rightIndex],
                   let twoRowsBack {
                    current[rightIndex + 1] = min(
                        current[rightIndex + 1],
                        twoRowsBack[rightIndex - 1] + 1
                    )
                }
                rowMinimum = min(rowMinimum, current[rightIndex + 1])
            }
            guard rowMinimum <= maximum else { return nil }
            twoRowsBack = previous
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
        // Reserve room for both omission markers before slicing so final
        // truncation never needs to cut a feasible match out of the excerpt.
        let contentCharacters = max(maximumCharacters - 2, 1)
        let before = contentCharacters / 3
        let start = text.index(
            center,
            offsetBy: -before,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            start,
            offsetBy: contentCharacters,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        var excerpt = String(text[start..<end])
        excerpt = excerpt.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\r" { return " " }
            if scalar == "\t" { return " " }
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar) {
                // Keep a separator so cleaning cannot concatenate two safe
                // source fragments into a credential-shaped projection.
                return " "
            }
            return String(scalar)
        }.joined()
        excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { excerpt = "…" + excerpt }
        if end < text.endIndex { excerpt += "…" }
        while (excerpt.count > maximumCharacters || excerpt.utf8.count > maximumBytes),
              !excerpt.isEmpty {
            excerpt.removeLast()
        }
        return excerpt
    }
}
