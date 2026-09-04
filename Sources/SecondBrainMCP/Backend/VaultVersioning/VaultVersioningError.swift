//
//  VaultVersioningError.swift
//  SecondBrainMCP
//
//  Created by BitBemol on 09/08/26.
//

/// Failures exposed by the vault-versioning boundary.
enum VaultVersioningError: Error, CallerSafeError, Sendable {
    /// Git launched but rejected or could not complete a command.
    ///
    /// Arguments and bounded standard error are retained so operational failures
    /// remain diagnosable without introducing a separate logging subsystem.
    case gitCommandFailed(
        arguments: [String],
        status: String,
        message: String
    )

    /// A Git subprocess exceeded the product-owned wall-clock deadline and its
    /// complete process group was terminated.
    case gitCommandTimedOut(arguments: [String])

    /// The repository location cannot represent a local filesystem directory.
    case invalidRepositoryURL

    /// Git attempted to replace note bytes with a nested-repository pointer.
    case embeddedRepositoryBelowNotes

    /// No canonical Apple-signed Git executable was available to the sandbox.
    case trustedGitUnavailable

    /// The validated vault directory pathname now names another filesystem object.
    case vaultRootChanged

    /// Notes recovery accepts stored bytes, not symbolic links or special entries.
    case unsupportedEntryBelowNotes

    /// Product-owned Git metadata was replaced with an unsafe layout.
    case invalidPrivateRepository

    /// Never expose Git arguments, status strings, or stderr to a tool caller.
    var callerSafeDescription: String {
        switch self {
        case .embeddedRepositoryBelowNotes:
            "Nested Git repositories under notes are unsupported; move the repository outside notes or remove its Git metadata, then retry."
        case .vaultRootChanged:
            "The vault directory changed while snapshotting; reopen the installed agent for the current vault, then retry."
        case .unsupportedEntryBelowNotes:
            "Symbolic links and special filesystem entries under notes are unsupported; replace them with regular files or directories, then retry."
        default:
            "Required vault snapshot failed; inspect current file state before retrying a mutation."
        }
    }

}
