import Foundation

/// Applies the write-boundary secret policy to bytes that already exist on disk.
///
/// Startup snapshots, directory moves, and commit-only recovery do not all pass
/// through ordinary CRUD preparation. They use this policy before Git can make
/// existing bytes durable.
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

    /// Validates one complete candidate before an existing file can enter Git.
    ///
    /// Known text formats receive their complete persisted-file policy, including
    /// structured HAR credential detection. Any candidate that is valid UTF-8
    /// receives the conservative text scan, while an unknown obvious text or
    /// configuration path cannot use one invalid byte to switch into the
    /// opaque-binary exemption.
    static func validateGitCandidate(
        _ data: Data,
        format: FileFormat?,
        path: String
    ) throws {
        if let format, format.isTextual {
            try validate(data, format: format, path: path)
            return
        }
        if String(data: data, encoding: .utf8) != nil {
            try SensitiveContentPolicy.validate(
                data,
                format: .log,
                path: path
            )
            return
        }
        guard format != nil || !isTextOrientedUnknownPath(path) else {
            throw TextFileSupport.TextError.invalidUTF8
        }
    }

    private static func isTextOrientedUnknownPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let fileExtension = (filename as NSString).pathExtension
        if fileExtension.isEmpty || filename.hasPrefix(".env") {
            return true
        }
        return [
            "bash", "conf", "config", "env", "fish", "ini", "js", "jsonl",
            "properties", "py", "rb", "sh", "toml", "ts", "txt", "xml",
            "yaml", "yml", "zsh",
        ].contains(fileExtension)
    }
}
