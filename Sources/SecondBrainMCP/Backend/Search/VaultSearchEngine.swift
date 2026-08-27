import Foundation

/// Small orchestration layer: validate, filter atoms, match, sort, and paginate.
struct VaultSearchEngine: VaultSearchService, Sendable {
    private enum Order { case before, same, after }

    private let source: any VaultSearchAtomSource
    private let strategy: any SearchMatchingStrategy

    init(
        source: any VaultSearchAtomSource,
        strategy: any SearchMatchingStrategy = LiteralSearchMatchingStrategy()
    ) {
        self.source = source
        self.strategy = strategy
    }

    func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse {
        let validated = try validate(request)
        let requestHash = try SearchCursorCodec.requestHash(validated)
        let atoms = try await source.atoms(in: validated.location)
        let corpusHash = try SearchCursorCodec.corpusHash(atoms)
        let cursor = try validated.cursor.map {
            try SearchCursorCodec.decode(
                $0,
                requestHash: requestHash,
                corpusHash: corpusHash
            )
        }
        let retainedCapacity = validated.limit + 1
        var observedCursorAnchor = cursor == nil
        var matches: [RankedSearchLocator] = []
        matches.reserveCapacity(min(atoms.count, retainedCapacity))
        for atom in atoms {
            try Task.checkCancellation()
            guard matchesMetadata(atom, request: validated) else { continue }
            let rank: SearchRank
            if let query = validated.query {
                guard let matched = strategy.rank(query: query, in: atom.text) else {
                    continue
                }
                rank = matched
            } else {
                rank = SearchRank(exactPhrase: false, occurrenceCount: 0)
            }
            let ranked = RankedSearchLocator(locator: atom.locator, rank: rank)
            if let cursor {
                switch order(ranked, cursor) {
                case .before:
                    continue
                case .same:
                    observedCursorAnchor = true
                    continue
                case .after:
                    break
                }
            }
            retain(
                ranked,
                in: &matches,
                capacity: retainedCapacity
            )
        }
        guard observedCursorAnchor else {
            throw VaultSearchRequestError.invalidCursor
        }
        matches.sort { order($0, $1) == .before }

        let returned = Array(matches.prefix(validated.limit))
        let nextCursor: String?
        if matches.count > returned.count, let last = returned.last {
            nextCursor = try SearchCursorCodec.encode(
                requestHash: requestHash,
                corpusHash: corpusHash,
                ranked: last
            )
        } else {
            nextCursor = nil
        }
        return VaultSearchResponse(
            results: returned.map(\.locator),
            nextCursor: nextCursor
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

    private func validate(_ request: VaultSearchRequest) throws -> VaultSearchRequest {
        let query = request.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = query?.isEmpty == false ? query : nil
        if let normalizedQuery,
           normalizedQuery.utf8.count > SearchRequestLimits.maximumQueryBytes {
            throw VaultSearchRequestError.queryTooLarge(
                limit: SearchRequestLimits.maximumQueryBytes
            )
        }

        let tags = request.tags.map(MarkdownSupport.normalizeTag)
        guard tags.count <= SearchRequestLimits.maximumTags,
              tags.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= SearchRequestLimits.maximumTagBytes
              }),
              Set(tags).count == tags.count else {
            throw VaultSearchRequestError.invalidTags
        }
        let stableTags = tags.sorted()
        if request.location != .notes,
           !stableTags.isEmpty || request.createdFrom != nil || request.createdThrough != nil {
            throw VaultSearchRequestError.metadataFiltersRequireNotes
        }
        if let value = request.createdFrom, !Self.isDate(value) {
            throw VaultSearchRequestError.invalidDate("created_from")
        }
        if let value = request.createdThrough, !Self.isDate(value) {
            throw VaultSearchRequestError.invalidDate("created_through")
        }
        if let from = request.createdFrom,
           let through = request.createdThrough,
           from > through {
            throw VaultSearchRequestError.invalidDateRange
        }
        guard normalizedQuery != nil
                || !stableTags.isEmpty
                || request.createdFrom != nil
                || request.createdThrough != nil else {
            throw VaultSearchRequestError.missingCriteria
        }
        guard (1...SearchRequestLimits.maximumResults).contains(request.limit) else {
            throw VaultSearchRequestError.invalidLimit(
                maximum: SearchRequestLimits.maximumResults
            )
        }
        if let cursor = request.cursor,
           cursor.isEmpty || cursor.utf8.count > SearchRequestLimits.maximumCursorBytes {
            throw VaultSearchRequestError.invalidCursor
        }
        return VaultSearchRequest(
            location: request.location,
            query: normalizedQuery,
            tags: stableTags,
            createdFrom: request.createdFrom,
            createdThrough: request.createdThrough,
            limit: request.limit,
            cursor: request.cursor
        )
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
            guard let created = metadata.created, Self.isDate(created) else {
                return false
            }
            if let from = request.createdFrom, created < from { return false }
            if let through = request.createdThrough, created > through { return false }
        }
        return true
    }

    private static func isDate(_ value: String) -> Bool {
        guard value.utf8.count == SearchRequestLimits.maximumDateBytes else {
            return false
        }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private func order(
        _ lhs: RankedSearchLocator,
        _ rhs: RankedSearchLocator
    ) -> Order {
        order(
            lhs,
            exactPhrase: rhs.rank.exactPhrase,
            occurrenceCount: rhs.rank.occurrenceCount,
            path: rhs.locator.path,
            format: rhs.locator.format,
            page: rhs.locator.page,
            canvasNodeID: rhs.locator.canvasNodeID,
            canvasField: rhs.locator.canvasField
        )
    }

    private func order(
        _ lhs: RankedSearchLocator,
        _ rhs: SearchCursorCodec.Payload
    ) -> Order {
        order(
            lhs,
            exactPhrase: rhs.exactPhrase,
            occurrenceCount: rhs.occurrenceCount,
            path: rhs.path,
            format: rhs.format,
            page: rhs.page,
            canvasNodeID: rhs.canvasNodeID,
            canvasField: rhs.canvasField
        )
    }

    private func order(
        _ lhs: RankedSearchLocator,
        exactPhrase: Bool,
        occurrenceCount: Int,
        path: String,
        format: FileFormat,
        page: Int?,
        canvasNodeID: String?,
        canvasField: String?
    ) -> Order {
        if lhs.rank.exactPhrase != exactPhrase {
            return lhs.rank.exactPhrase ? .before : .after
        }
        if lhs.rank.occurrenceCount != occurrenceCount {
            return lhs.rank.occurrenceCount > occurrenceCount ? .before : .after
        }
        if lhs.locator.path != path {
            return lhs.locator.path < path ? .before : .after
        }
        if lhs.locator.format != format {
            return lhs.locator.format.rawValue < format.rawValue ? .before : .after
        }
        let lhsPage = lhs.locator.page ?? 0
        let rhsPage = page ?? 0
        if lhsPage != rhsPage { return lhsPage < rhsPage ? .before : .after }
        let lhsNodeID = lhs.locator.canvasNodeID ?? ""
        let rhsNodeID = canvasNodeID ?? ""
        if lhsNodeID != rhsNodeID { return lhsNodeID < rhsNodeID ? .before : .after }
        let lhsField = lhs.locator.canvasField ?? ""
        let rhsField = canvasField ?? ""
        if lhsField != rhsField { return lhsField < rhsField ? .before : .after }
        return .same
    }
}
