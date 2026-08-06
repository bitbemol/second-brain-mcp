import Foundation

/// Path-agnostic filesystem primitive for inspecting regular files.
///
/// Domain trust boundaries map these structural failures to their own errors and
/// apply containment, extension, or size policy after this shared inspection.
enum RegularFileInspector {
    /// Structural failures independent of a vault or external-source context.
    enum InspectionError: Error, Sendable {
        /// No filesystem entry exists at the supplied URL.
        case notFound
        /// The filesystem entry exists but is not a regular file.
        case notARegularFile
    }

    /// Inspects an absolute file URL without applying domain-specific policy.
    ///
    /// - Parameter url: Absolute or canonical URL to inspect.
    /// - Returns: Immutable metadata for the regular file.
    /// - Throws: ``InspectionError`` or a filesystem metadata error.
    static func inspect(_ url: URL) throws -> RegularFileMetadata {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw InspectionError.notFound
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw InspectionError.notARegularFile
        }
        return RegularFileMetadata(
            byteCount: (attributes[.size] as? Int) ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}
