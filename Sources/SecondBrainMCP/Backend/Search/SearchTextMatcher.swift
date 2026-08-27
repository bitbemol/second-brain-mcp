import Foundation

/// Deterministic literal matching independent of vault and file representations.
struct LiteralSearchMatchingStrategy: SearchMatchingStrategy {
    func rank(query: String, in text: String) -> SearchRank? {
        prepare(query: query)(text)
    }

    func prepare(query: String) -> @Sendable (String) -> SearchRank? {
        let normalizedQuery = Self.normalize(query)
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
        let terms = distinctTerms.map { (term: $0, frequency: termFrequencies[$0] ?? 0) }
        return { text in
            let normalizedText = Self.normalize(text)
            guard !terms.isEmpty,
                  terms.allSatisfy({ normalizedText.contains($0.term) }) else { return nil }
            let phrase = normalizedText.contains(normalizedQuery)
            let occurrences = terms.reduce(into: 0) { total, entry in
                total += Self.occurrenceCount(of: entry.term, in: normalizedText) * entry.frequency
            }
            return SearchRank(exactPhrase: phrase, occurrenceCount: occurrences)
        }
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
