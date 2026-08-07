import Foundation

/// Single filesystem trust boundary for already validated vault targets.
///
/// Path targets prove containment and extension agreement; this inspector proves
/// that the resolved entry currently exists and is a regular file before any
/// generic or format-specific reader opens it.
enum VaultFileInspector {
    /// Failures raised while inspecting a validated vault target.
    enum InspectionError: Error, CustomStringConvertible, Sendable {
        /// No filesystem entry exists at the target path.
        case notFound(String)
        /// The target exists but is not a regular file.
        case notARegularFile(String)

        /// Human-readable inspection failure.
        var description: String {
            switch self {
            case .notFound(let path):
                "File not found: \(path)"
            case .notARegularFile(let path):
                "Path is not a regular file: \(path)"
            }
        }
    }

    /// Inspects the current filesystem entry for a validated target.
    ///
    /// - Parameter target: Contained, extension-checked vault target.
    /// - Returns: Immutable metadata for the regular file.
    /// - Throws: ``InspectionError`` or a filesystem metadata error.
    static func inspect(_ target: ReadableFileTarget) throws -> RegularFileMetadata {
        try target.revalidate()
        do {
            return try RegularFileInspector.inspect(target.url)
        } catch RegularFileInspector.InspectionError.notFound {
            throw InspectionError.notFound(target.relativePath)
        } catch RegularFileInspector.InspectionError.notARegularFile {
            throw InspectionError.notARegularFile(target.relativePath)
        }
    }

    /// Opens and snapshots a contained target through one stable descriptor.
    static func snapshot(
        _ target: ReadableFileTarget,
        maximumBytes: Int
    ) throws -> BoundedFileReader.Snapshot {
        try target.revalidate()
        do {
            return try BoundedFileReader.snapshot(
                fromCanonical: target.url,
                maximumBytes: maximumBytes,
                path: target.relativePath
            )
        } catch BoundedFileReader.ReadError.notFound {
            throw InspectionError.notFound(target.relativePath)
        } catch BoundedFileReader.ReadError.notARegularFile {
            throw InspectionError.notARegularFile(target.relativePath)
        }
    }
}
