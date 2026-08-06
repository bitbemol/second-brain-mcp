import Foundation

/// Immutable frontend configuration derived from process arguments.
struct ServerConfig: Sendable {
    /// Canonical path to the vault root.
    let vaultPath: String
    /// Whether mutation tools and capabilities are disabled.
    let readOnly: Bool

    /// User-facing failures raised while parsing and validating CLI arguments.
    enum ConfigError: Error, CustomStringConvertible {
        /// The required `--vault` option or its value is absent.
        case missingVaultPath
        /// The expanded vault path does not exist.
        case vaultNotFound(String)
        /// The expanded vault path exists but is not a directory.
        case vaultNotDirectory(String)

        /// Human-readable command-line configuration failure.
        var description: String {
            switch self {
            case .missingVaultPath:
                return "Missing required argument: --vault <path>"
            case .vaultNotFound(let path):
                return "Vault path does not exist: \(path)"
            case .vaultNotDirectory(let path):
                return "Vault path is not a directory: \(path)"
            }
        }
    }

    /// Parses process arguments into validated frontend configuration.
    ///
    /// Recognized options are `--vault <path>` and `--read-only`. Unknown
    /// arguments are ignored for forward and legacy compatibility.
    ///
    /// - Parameter arguments: Complete process argument vector, including argv[0].
    /// - Returns: A configuration whose vault path exists and is a directory.
    /// - Throws: ``ConfigError`` when the required vault argument is invalid.
    static func parse(arguments: [String]) throws -> ServerConfig {
        let args = Array(arguments.dropFirst())
        var vaultPath: String?
        var readOnly = false

        var index = 0
        while index < args.count {
            switch args[index] {
            case "--vault":
                index += 1
                guard index < args.count else { throw ConfigError.missingVaultPath }
                vaultPath = args[index]
            case "--read-only":
                readOnly = true
            default:
                break
            }
            index += 1
        }

        guard let vaultPath else { throw ConfigError.missingVaultPath }
        let expandedPath = (vaultPath as NSString).expandingTildeInPath
        guard !expandedPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ConfigError.missingVaultPath
        }
        let resolvedPath = URL(fileURLWithPath: expandedPath)
            .standardized
            .resolvingSymlinksInPath()
            .path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: resolvedPath,
            isDirectory: &isDirectory
        ) else {
            throw ConfigError.vaultNotFound(resolvedPath)
        }
        guard isDirectory.boolValue else {
            throw ConfigError.vaultNotDirectory(resolvedPath)
        }
        return ServerConfig(vaultPath: resolvedPath, readOnly: readOnly)
    }
}
