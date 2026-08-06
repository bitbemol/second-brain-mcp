import Foundation

/// Applies the write-boundary secret policy to bytes that already exist on disk.
///
/// Startup snapshots and commit-only recovery do not pass through ordinary CRUD
/// preparation. They use this policy before Git can make those bytes durable.
enum PersistedFileSecurityPolicy {
    /// Existing bytes cannot safely enter Git history.
    struct Violation: Error, CustomStringConvertible, Sendable {
        let path: String
        let reason: String

        var description: String {
            "Refusing to commit \(path): \(reason)"
        }
    }

    /// Validates one complete stored file without mutating it.
    static func validate(
        _ data: Data,
        format: FileFormat,
        path: String
    ) throws {
        if format == .har {
            let sanitized: HARSensitiveDataSanitizer.Result
            do {
                sanitized = try HARSensitiveDataSanitizer.sanitize(data)
            } catch {
                throw Violation(path: path, reason: "HAR JSON is ambiguous or invalid")
            }
            guard sanitized.redactionCount == 0 else {
                throw Violation(path: path, reason: "HAR contains credential-bearing fields")
            }
            try SensitiveContentPolicy.validate(
                sanitized.data,
                format: format,
                path: path
            )
            return
        }
        try SensitiveContentPolicy.validate(data, format: format, path: path)
    }
}
