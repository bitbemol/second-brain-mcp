/// Shared typo-tolerance policy used by candidate selection and final matching.
enum SearchFuzzyPolicy {
    /// Conservative edit allowance for one normalized query term.
    static func maximumEditDistance(for normalizedTerm: String) -> Int {
        let length = normalizedTerm.unicodeScalars.count
        if length < 3 { return 0 }
        return length <= 7 ? 1 : 2
    }

    /// Computes bounded optimal-string-alignment distance without external work accounting.
    static func boundedDistance(
        _ lhs: String,
        _ rhs: String,
        maximum: Int
    ) -> Int? {
        boundedDistance(lhs, rhs, maximum: maximum, consumingCell: { true })
    }

    /// Computes bounded optimal-string-alignment distance while charging every matrix cell.
    ///
    /// Adjacent transposition is one edit, but a scalar cannot participate in
    /// multiple transpositions. Returning `false` from `consumingCell` stops work.
    static func boundedDistance(
        _ lhs: String,
        _ rhs: String,
        maximum: Int,
        consumingCell: () -> Bool
    ) -> Int? {
        let left = lhs.unicodeScalars.map(\.value)
        let right = rhs.unicodeScalars.map(\.value)
        guard maximum >= 0,
              abs(left.count - right.count) <= maximum else { return nil }

        var twoRowsBack: [Int]?
        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            var rowMinimum = current[0]
            for rightIndex in right.indices {
                guard consumingCell() else { return nil }
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
}
