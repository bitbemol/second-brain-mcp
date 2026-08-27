import Foundation

/// Validate before IO, then consume bounded documents without retaining the corpus.
struct VaultSearchEngine: VaultSearchService, Sendable {
    private let source: any VaultSearchAtomSource
    private let strategy: any SearchMatchingStrategy

    init(source: any VaultSearchAtomSource,
         strategy: any SearchMatchingStrategy = LiteralSearchMatchingStrategy()) {
        self.source = source
        self.strategy = strategy
    }

    var searchableFormats: [FileFormat] { source.searchableFormats }

    func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse {
        let validated = try validate(request)
        let requestHash = try SearchCursorCodec.requestHash(validated)
        let cursor = try validated.cursor.map {
            try SearchCursorCodec.decode($0, requestHash: requestHash)
        }
        let page = SearchPageAccumulator(
            request: validated, requestHash: requestHash, cursor: cursor, strategy: strategy
        )
        let formats = try await source.scan(validated) { try await page.consume($0) }
        return try await page.response(searchedFormats: formats)
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
        if let directory = request.directory {
            guard !directory.isEmpty, directory != ".", !directory.hasPrefix("/"),
                  !directory.hasSuffix("/"),
                  directory.utf8.count <= FileListingRequestLimits.maximumDirectoryBytes else {
                throw VaultSearchRequestError.invalidScope
            }
        }
        guard Set(request.formats).count == request.formats.count else {
            throw VaultSearchRequestError.invalidScope
        }
        if !stableTags.isEmpty || request.createdFrom != nil || request.createdThrough != nil {
            guard request.formats.isEmpty || request.formats.contains(.markdown) else {
                throw VaultSearchRequestError.invalidScope
            }
        }
        return VaultSearchRequest(
            location: request.location,
            directory: request.directory,
            formats: request.formats.sorted { $0.rawValue < $1.rawValue },
            query: normalizedQuery,
            tags: stableTags,
            createdFrom: request.createdFrom,
            createdThrough: request.createdThrough,
            limit: request.limit,
            cursor: request.cursor
        )
    }

    static func isDate(_ value: String) -> Bool {
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

}
