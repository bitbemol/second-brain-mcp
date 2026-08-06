import Foundation

/// Validates HTTP Archive files and produces compact traffic summaries.
///
/// Credential-bearing fields are sanitized before persistence. Reads return
/// summary data by default and include only the sanitized JSON when the caller
/// explicitly requests raw output.
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

    /// Summarizes a HAR snapshot, optionally including its complete JSON payload.
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
        let inspection = try HARInspector.inspect(data: sanitized.data)
        let summary = Self.summary(inspection: inspection, path: target.relativePath)
        // Legacy archives may carry credentials in descriptive fields such as
        // creator name, version, or method. Validate the projection as well as
        // raw JSON so summary-only reads cannot disclose those values.
        try SensitiveContentPolicy.validate(
            Data(summary.utf8),
            format: .har,
            path: target.relativePath
        )
        if request.options.raw {
            try SensitiveContentPolicy.validate(
                sanitized.data,
                format: .har,
                path: target.relativePath
            )
            return .text(
                summary + "\n\n"
                    + (try TextFileSupport.string(from: sanitized.data))
            )
        }
        return .text(summary + "\n\nPass raw=true to include the complete HAR JSON.")
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
