/// Validated HTTP Archive facts used to render compact traffic summaries.
struct HARInspection: Equatable, Sendable {
    /// Nonempty HAR version declared by `log.version`.
    let version: String
    /// Tool name declared by `log.creator.name`.
    let creatorName: String
    /// Number of entries in `log.entries`.
    let entryCount: Int
    /// Number of distinct valid request URL hosts.
    let hostCount: Int
    /// Sum of valid entry timing values in milliseconds.
    let totalTimeMilliseconds: Double
    /// Request counts keyed by valid method name.
    let methods: [String: Int]
    /// Response counts keyed by valid HTTP status.
    let statuses: [Int: Int]
}
