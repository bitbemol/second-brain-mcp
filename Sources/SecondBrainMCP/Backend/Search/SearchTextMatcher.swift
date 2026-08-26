import Foundation

/// Deterministic literal matching independent of vault and file representations.
struct LiteralSearchMatchingStrategy: SearchMatchingStrategy {
    func rank(query: String, in text: String) -> SearchRank? {
        let normalizedQuery = Self.normalize(query)
        let normalizedText = Self.normalize(text)
        var termFrequencies: [String: Int] = [:]
        var distinctTerms: [String] = []
        for termSlice in normalizedQuery.split(whereSeparator: \.isWhitespace) {
            let term = String(termSlice)
            let frequency = termFrequencies[term, default: 0]
            termFrequencies[term] = frequency + 1
            if frequency == 0 {
                distinctTerms.append(term)
            }
        }
        guard !distinctTerms.isEmpty,
              distinctTerms.allSatisfy({ normalizedText.contains($0) }) else {
            return nil
        }
        let phrase = normalizedText.contains(normalizedQuery)
        let occurrences = distinctTerms.reduce(into: 0) { total, term in
            total += Self.occurrenceCount(of: term, in: normalizedText)
                * (termFrequencies[term] ?? 0)
        }
        return SearchRank(exactPhrase: phrase, occurrenceCount: occurrences)
    }

    static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func occurrenceCount(of term: String, in text: String) -> Int {
        var count = 0
        var remainder = text[...]
        while let range = remainder.range(of: term) {
            count += 1
            remainder = remainder[range.upperBound...]
        }
        return count
    }
}
