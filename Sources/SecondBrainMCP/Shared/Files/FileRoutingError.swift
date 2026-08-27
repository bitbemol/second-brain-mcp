/// An error whose deliberately bounded description is safe to return to an untrusted caller.
protocol CallerSafeError: Error {
    var callerSafeDescription: String { get }
}

/// Domain errors raised before a file operation reaches persistence.
enum FileRoutingError: Error, CustomStringConvertible, CallerSafeError {
    /// A raw transport value does not identify a supported concrete format.
    case unknownFormat(String)
    /// A path is outside every recognized vault area.
    case invalidArea(String)
    /// A mutation target resolves to a structurally read-only vault area.
    case areaNotWritable(String)
    /// The runtime was bootstrapped without mutation permission.
    case readOnly
    /// The declared format does not accept the destination extension.
    case extensionMismatch(path: String, format: FileFormat)
    /// Media inspection disagrees with the caller's declared format.
    case contentMismatch(path: String, declared: FileFormat, detected: String)
    /// The format catalog has no binding for this operation and area.
    case operationNotSupported(
        format: FileFormat,
        operation: FileCRUDOperation,
        area: VaultArea
    )
    /// Read selectors are invalid or conflict for the declared format.
    case invalidReadOptions(String)
    /// Mutable note bytes no longer match the revision supplied by the caller.
    case revisionConflict(String)

    var callerSafeDescription: String {
        switch self {
        case .unknownFormat:
            "Unsupported file format: choose a listed concrete format"
        case .invalidArea:
            "Path must be within notes/ or references/"
        case .areaNotWritable:
            "Writable file paths must be within notes/"
        case .extensionMismatch(_, let format):
            "Path extension does not match format '\(format.rawValue)'. Allowed extensions: "
                + format.extensions.sorted().joined(separator: ", ")
        case .contentMismatch(_, let declared, _):
            "File content does not match declared format '\(declared.rawValue)'"
        case .revisionConflict:
            "File changed since it was read: read it again before updating or deleting it."
        case .readOnly, .operationNotSupported, .invalidReadOptions:
            description
        }
    }

    /// Internal routing diagnostic; caller-facing errors omit arbitrary identity values.
    var description: String {
        switch self {
        case .unknownFormat(let value):
            return "Unsupported file format: \(value)"
        case .invalidArea(let path):
            return "Path must be within notes/ or references/: \(path)"
        case .areaNotWritable(let path):
            return "Writable file paths must be within notes/: \(path)"
        case .readOnly:
            return "Server is running in read-only mode; mutations are not permitted"
        case .extensionMismatch(let path, let format):
            return "Path extension does not match format '\(format.rawValue)': "
                + "\(path). Allowed extensions: "
                + format.extensions.sorted().joined(separator: ", ")
        case .contentMismatch(let path, let declared, let detected):
            return "File content does not match declared format "
                + "'\(declared.rawValue)' at \(path); detected \(detected)"
        case .operationNotSupported(let format, let operation, let area):
            return "Operation '\(operation.rawValue)' is not supported for "
                + "'\(format.rawValue)' files in \(area.rawValue)/"
        case .invalidReadOptions(let message):
            return "Invalid read options: \(message)"
        case .revisionConflict(let path):
            return "File changed since it was read: \(path). Read it again "
                + "before updating or deleting it."
        }
    }
}
