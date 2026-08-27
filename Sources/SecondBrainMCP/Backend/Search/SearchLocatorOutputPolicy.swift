import Foundation

/// Discovery limits do not change stored Canvas validity or direct read selectors.
enum SearchLocatorOutputPolicy {
    static func fits(_ locator: VaultSearchResult) throws -> Bool {
        let limit = SearchRequestLimits.maximumLocatorBytes
        let rawBytes = locator.path.utf8.count + locator.format.rawValue.utf8.count
            + (locator.canvasNodeID?.utf8.count ?? 0)
            + (locator.canvasField?.utf8.count ?? 0)
        guard rawBytes <= limit else { return false }
        // JSON string escaping uses at most six bytes per input UTF-8 byte.
        // 256 covers all fixed keys, quotes, punctuation and a 64-bit page number.
        // Ordinary short locators avoid allocating an encoder or encoded Data.
        if rawBytes <= (limit - 256) / 6 { return true }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(locator).count <= limit
    }
}
