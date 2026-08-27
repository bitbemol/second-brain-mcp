import Foundation

/// Only locators for one bounded page survive each complete document.
actor SearchPageAccumulator {
    private enum Order { case before, same, after }
    private let request: VaultSearchRequest
    private let requestHash: String
    private let cursor: SearchCursorCodec.Payload?
    private let matcher: (@Sendable (String) -> SearchRank?)?
    private var fingerprint = SearchFingerprint(domain: "search-corpus-v2")
    private var coverage = DiscoveryCoverageAccumulator()
    private var matches: [RankedSearchLocator] = []
    private var ordinal = 0
    private var observedCursorAnchor: Bool

    init(request: VaultSearchRequest, requestHash: String,
         cursor: SearchCursorCodec.Payload?, strategy: any SearchMatchingStrategy) {
        self.request = request
        self.requestHash = requestHash
        self.cursor = cursor
        self.matcher = request.query.map { strategy.prepare(query: $0) }
        self.observedCursorAnchor = cursor == nil
        matches.reserveCapacity(request.limit + 1)
    }

    func consume(_ document: SearchDocument) throws {
        try Task.checkCancellation()
        var failure = document.failure
        if failure == nil {
            // Preflight before committing any of this file's ranking or cursor state.
            for atom in document.atoms {
                try Task.checkCancellation()
                if try !SearchLocatorOutputPolicy.fits(atom.locator) {
                    failure = .fileLimit
                    break
                }
            }
        }
        fingerprint.append(document.path)
        fingerprint.append(document.format.rawValue)
        fingerprint.append(document.revision?.rawValue)
        if let reason = failure {
            fingerprint.append("failure")
            fingerprint.append(reason.rawValue)
            coverage.record(path: document.path, reason: reason, format: document.format)
            return
        }
        fingerprint.append("complete")
        fingerprint.append(String(document.atoms.count))
        // Providers finish validation before this commit; failed files never affect ranking.
        for atom in document.atoms.sorted(by: SearchFingerprint.precedes) {
            try Task.checkCancellation()
            fingerprint.append(atom)
            let currentOrdinal = ordinal
            ordinal += 1
            guard matchesMetadata(atom, request: request) else { continue }
            let rank: SearchRank
            if let matcher {
                guard let matched = matcher(atom.text) else { continue }
                rank = matched
            } else {
                rank = SearchRank(exactPhrase: false, occurrenceCount: 0)
            }
            let ranked = RankedSearchLocator(
                locator: atom.locator, rank: rank, ordinal: currentOrdinal
            )
            if let cursor {
                let comparison = order(
                    ranked, rank: cursor.rank, ordinal: cursor.ordinal
                )
                if comparison == .same {
                    observedCursorAnchor = SearchFingerprint.locatorID(atom.locator) == cursor.anchorID
                    continue
                }
                if comparison == .before { continue }
            }
            retain(ranked, in: &matches, capacity: request.limit + 1)
        }
    }

    func response(searchedFormats: Set<FileFormat>) throws -> VaultSearchResponse {
        let corpusHash = fingerprint.value
        if let cursor, cursor.corpusHash != corpusHash {
            throw VaultSearchRequestError.staleCursor
        }
        guard observedCursorAnchor else { throw VaultSearchRequestError.invalidCursor }
        matches.sort { order($0, $1) == .before }
        let returned = Array(matches.prefix(request.limit))
        let nextCursor = try matches.count > returned.count ? returned.last.map {
            try SearchCursorCodec.encode(requestHash: requestHash, corpusHash: corpusHash, ranked: $0)
        } : nil
        return VaultSearchResponse(
            results: returned.map(\.locator), nextCursor: nextCursor, coverage: coverage.searchValue(formats: searchedFormats)
        )
    }

    /// Retains only the best bounded page plus one continuation sentinel.
    ///
    /// The array is maintained as a worst-first binary heap while scanning, then
    /// sorted once after it contains at most the requested limit plus one entry.
    private func retain(
        _ candidate: RankedSearchLocator,
        in heap: inout [RankedSearchLocator],
        capacity: Int
    ) {
        if heap.count < capacity {
            heap.append(candidate)
            siftUpWorst(in: &heap, from: heap.count - 1)
            return
        }
        guard let worst = heap.first,
              order(candidate, worst) == .before else {
            return
        }
        heap[0] = candidate
        siftDownWorst(in: &heap, from: 0)
    }

    private func siftUpWorst(
        in heap: inout [RankedSearchLocator],
        from start: Int
    ) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard order(heap[parent], heap[index]) == .before else {
                return
            }
            heap.swapAt(parent, index)
            index = parent
        }
    }

    private func siftDownWorst(
        in heap: inout [RankedSearchLocator],
        from start: Int
    ) {
        var index = start
        while true {
            let left = index * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            let worseChild: Int
            if right < heap.count,
               order(heap[left], heap[right]) == .before {
                worseChild = right
            } else {
                worseChild = left
            }
            guard order(heap[index], heap[worseChild]) == .before else {
                return
            }
            heap.swapAt(index, worseChild)
            index = worseChild
        }
    }

    private func matchesMetadata(
        _ atom: SearchAtom,
        request: VaultSearchRequest
    ) -> Bool {
        guard !request.tags.isEmpty
                || request.createdFrom != nil
                || request.createdThrough != nil else {
            return true
        }
        guard let metadata = atom.metadata else { return false }
        if !request.tags.allSatisfy(metadata.tags.contains) { return false }
        if request.createdFrom != nil || request.createdThrough != nil {
            guard let created = metadata.created, VaultSearchEngine.isDate(created) else {
                return false
            }
            if let from = request.createdFrom, created < from { return false }
            if let through = request.createdThrough, created > through { return false }
        }
        return true
    }

    private func order(_ lhs: RankedSearchLocator, _ rhs: RankedSearchLocator) -> Order {
        order(lhs, rank: rhs.rank, ordinal: rhs.ordinal)
    }

    private func order(_ lhs: RankedSearchLocator, rank: SearchRank, ordinal: Int) -> Order {
        if lhs.rank.exactPhrase != rank.exactPhrase {
            return lhs.rank.exactPhrase ? .before : .after
        }
        if lhs.rank.occurrenceCount != rank.occurrenceCount {
            return lhs.rank.occurrenceCount > rank.occurrenceCount ? .before : .after
        }
        if lhs.ordinal != ordinal { return lhs.ordinal < ordinal ? .before : .after }
        return .same
    }
}
