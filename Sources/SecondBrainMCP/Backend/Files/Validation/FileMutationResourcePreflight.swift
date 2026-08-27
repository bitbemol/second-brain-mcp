/// Bounds caller-controlled mutation text before fingerprinting or format parsing.
///
/// Prepared output is still checked at the persistence boundary. This earlier
/// check prevents a request that can never be stored from consuming memory in
/// Codable fingerprinting, exact-patch search, or a structured format parser.
enum FileMutationResourcePreflight {
    /// Caller metadata exceeded its transport-neutral request budget.
    struct Violation: Error, CustomStringConvertible, Sendable {
        let field: String

        var description: String {
            "Mutation request contains too much \(field) data"
        }
    }

    /// Validates inline creation content against the destination format limit.
    static func validate(_ request: CreateFileRequest) throws {
        if let content = request.content {
            try FileResourcePolicy.validate(
                bytes: content.utf8.count,
                format: request.format,
                path: request.path
            )
        }
        if let source = request.source,
           source.utf8.count > FileMutationRequestLimits.maximumSourcePathBytes {
            throw Violation(field: "source path")
        }
        guard request.tags.count <= FileMutationRequestLimits.maximumTagCount else {
            throw Violation(field: "tag")
        }
        var aggregateTagBytes = 0
        for tag in request.tags {
            let tagBytes = tag.utf8.count
            guard tagBytes <= FileMutationRequestLimits.maximumTagBytes else {
                throw Violation(field: "tag")
            }
            let (sum, overflow) = aggregateTagBytes.addingReportingOverflow(tagBytes)
            guard !overflow,
                  sum <= FileMutationRequestLimits.maximumAggregateTagBytes else {
                throw Violation(field: "tag")
            }
            aggregateTagBytes = sum
        }
    }

    /// Validates replacement content and the aggregate exact-patch payload.
    static func validate(_ request: UpdateFileRequest) throws {
        if let content = request.content {
            try FileResourcePolicy.validate(
                bytes: content.utf8.count,
                format: request.format,
                path: request.path
            )
        }
        guard !request.replacements.isEmpty else { return }
        guard request.replacements.count <= FileMutationRequestLimits.maximumReplacements else {
            throw TextFileSupport.TextError.tooManyPatches(
                request.replacements.count
            )
        }

        var bytes = 0
        for replacement in request.replacements {
            for value in [replacement.oldText, replacement.newText] {
                let (sum, overflow) = bytes.addingReportingOverflow(
                    value.utf8.count
                )
                bytes = overflow ? Int.max : sum
            }
        }
        // A valid replacement may legitimately carry one near-limit search
        // value and one near-limit replacement value while still producing a
        // file within the stored-size limit. Bound request material separately
        // at twice the stored-file limit; final output keeps the stricter limit.
        let storedLimit = request.format.maximumFileBytes
        let (doubledLimit, overflow) = storedLimit.multipliedReportingOverflow(
            by: 2
        )
        try FileResourcePolicy.validate(
            bytes: bytes,
            format: request.format,
            path: request.path,
            maximumBytes: overflow ? Int.max : doubledLimit
        )
    }
}
