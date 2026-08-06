/// Failures produced while launching or executing a Git command.
enum GitCommandError: Error, CustomStringConvertible, Sendable {
    /// The configured Git executable is unavailable.
    case executableNotFound(path: String)
    /// The operating system could not launch Git.
    case launchFailed(command: String, reason: String)
    /// Git launched but exited unsuccessfully.
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    /// Human-readable command execution failure.
    var description: String {
        switch self {
        case .executableNotFound(let path):
            return "Git not found at \(path)"
        case .launchFailed(let command, let reason):
            return "Could not launch Git command (\(command)): \(reason)"
        case .commandFailed(let command, let exitCode, let stderr):
            return "Git command failed (\(command), exit \(exitCode)): \(stderr)"
        }
    }
}
