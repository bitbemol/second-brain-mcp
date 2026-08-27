import Foundation

/// Validates and sanitizes HTTP Archive files.
///
/// Credential-bearing fields are redacted before persistence. Reads validate the
/// complete sanitized document before returning a bounded UTF-8 byte window.
struct HARFileOperations: Sendable {
    /// Validates a centrally loaded HAR payload before generic persistence.
    ///
    /// - Parameters:
    ///   - input: Centrally validated HAR bytes.
    ///   - target: Validated destination included in the archive summary.
    /// - Returns: Valid HAR bytes and their compact creation summary.
    /// - Throws: ``HARInspector/InspectionError`` when required archive structure
    ///   is absent.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        let sanitized: HARSensitiveDataSanitizer.Result
        do {
            sanitized = try HARSensitiveDataSanitizer.sanitize(input.data)
        } catch is HARSensitiveDataSanitizer.InvalidJSON {
            throw HARInspector.InspectionError.invalidJSON
        }
        try FileResourcePolicy.validate(
            bytes: sanitized.data.count,
            format: .har,
            path: target.relativePath
        )
        let inspection = try HARInspector.inspect(data: sanitized.data)
        let summary = Self.summary(inspection: inspection, path: target.relativePath)
        let sanitization = sanitized.redactionCount == 0
            ? ""
            : "\nSanitized \(sanitized.redactionCount) sensitive value(s) before storage."
        return PreparedFileWrite(
            data: sanitized.data,
            output: .text(
                "Created \(target.relativePath)\n\(summary)\(sanitization)"
            )
        )
    }

    /// Validates the complete sanitized HAR JSON and returns one bounded text window.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        let sanitized: HARSensitiveDataSanitizer.Result
        do {
            sanitized = try HARSensitiveDataSanitizer.sanitize(snapshot.data)
        } catch is HARSensitiveDataSanitizer.InvalidJSON {
            throw HARInspector.InspectionError.invalidJSON
        }
        _ = try HARInspector.inspect(data: sanitized.data)
        try SensitiveContentPolicy.validate(
            sanitized.data,
            format: .har,
            path: target.relativePath
        )
        let chunk = try TextFileSupport.readChunk(
            from: sanitized.data,
            byteOffset: request.options.byteOffset ?? 0,
            maximumBytes: request.options.maxBytes
                ?? FileReadRequestLimits.defaultTextChunkBytes
        )
        return .text(chunk.text, textWindow: chunk.window)
    }

    /// Describes validated HAR requests, responses, and timing.
    ///
    /// - Parameters:
    ///   - inspection: Typed archive facts returned by ``HARInspector``.
    ///   - path: Vault-relative path displayed in the summary.
    /// - Returns: A compact, line-oriented archive summary.
    private static func summary(
        inspection: HARInspection,
        path: String
    ) -> String {
        let methodSummary = inspection.methods.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let statusSummary = inspection.statuses.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return [
            "HAR: \(path)",
            "Version: \(inspection.version) · Creator: \(inspection.creatorName)",
            "Entries: \(inspection.entryCount) · Hosts: \(inspection.hostCount) "
                + "· Total recorded time: "
                + "\(String(format: "%.0f", inspection.totalTimeMilliseconds)) ms",
            "Methods: \(methodSummary.isEmpty ? "(none)" : methodSummary)",
            "Statuses: \(statusSummary.isEmpty ? "(none)" : statusSummary)"
        ].joined(separator: "\n")
    }
}
