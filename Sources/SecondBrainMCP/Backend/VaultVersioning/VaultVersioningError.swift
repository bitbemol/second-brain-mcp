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

    /// The repository location cannot represent a local filesystem directory.
    case invalidRepositoryURL

    /// Never expose Git arguments, status strings, or stderr to a tool caller.
    var callerSafeDescription: String {
        "Required vault snapshot failed; inspect current file state before retrying a mutation."
    }

}
