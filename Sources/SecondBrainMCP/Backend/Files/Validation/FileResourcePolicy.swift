import Foundation

/// Single backend authority for supported vault-file byte limits.
///
/// The policy applies to inline ingress, prepared writes, snapshots, and
/// specialized readers. Media components may use smaller injected limits in
/// tests, but their production defaults derive from this type.
enum FileResourcePolicy {
    /// A managed file or prepared write exceeds its effective byte limit.
    struct Violation: Error, CustomStringConvertible, Sendable {
        /// Vault-relative path or operation description associated with the data.
        let path: String
        /// Observed byte count.
        let bytes: Int
        /// Maximum permitted byte count.
        let limit: Int

        /// Human-readable resource-policy failure.
        var description: String {
            "File is too large: \(path) is \(bytes) bytes (limit \(limit))"
        }
    }

    /// Returns the maximum supported bytes for one concrete vault format.
    ///
    /// - Parameter format: Concrete stored format.
    /// - Returns: Maximum size accepted for storage and reading.
    static func maximumBytes(for format: FileFormat) -> Int {
        switch format {
        case .markdown, .canvas, .patch, .json, .csv:
            10 * 1024 * 1024
        case .har, .log, .png, .jpeg, .gif, .webp, .heic, .tiff, .bmp:
            25 * 1024 * 1024
        case .pdf:
            512 * 1024 * 1024
        }
    }

    /// Validates an observed byte count against a format or injected limit.
    ///
    /// - Parameters:
    ///   - bytes: Observed data size.
    ///   - format: Concrete format whose production policy applies.
    ///   - path: Path or preparation description used in diagnostics.
    ///   - maximumBytes: Optional stricter limit used by injected test policy.
    /// - Throws: ``Violation`` when `bytes` exceeds the effective limit.
    static func validate(
        bytes: Int,
        format: FileFormat,
        path: String,
        maximumBytes: Int? = nil
    ) throws {
        let limit = maximumBytes ?? self.maximumBytes(for: format)
        guard bytes <= limit else {
            throw Violation(path: path, bytes: bytes, limit: limit)
        }
    }
}

extension FileFormat {
    /// Maximum supported bytes for a stored or read vault file of this format.
    var maximumFileBytes: Int {
        FileResourcePolicy.maximumBytes(for: self)
    }
}
