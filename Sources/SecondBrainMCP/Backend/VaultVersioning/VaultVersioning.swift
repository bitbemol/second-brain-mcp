//
//  VaultVersioning.swift
//  SecondBrainMCP
//
//  Created by BitBemol on 09/08/26.
//

/// Records recoverable states of a notes vault without exposing the underlying
/// version-control implementation.
///
/// Full reconciliation captures the current notes state. A validated mutation
/// may instead publish only its changed paths against the latest recoverable
/// state so unrelated work-tree files are not read or hashed.
protocol VaultVersioning: Sendable {
    /// Records the current vault state if it differs from the latest snapshot.
    ///
    /// Returning normally means the state is recoverable. It does not guarantee
    /// that this particular call created a new version.
    func recordSnapshot() async throws

    /// Records the current mutation footprint before persistence so the exact
    /// pre-change state remains recoverable.
    func prepareForMutation(changing paths: [String]?) async throws

    /// Records only the named notes paths after a validated MCP mutation.
    /// Implementations that do not optimize this scope may fall back to a full snapshot.
    func recordSnapshot(changing paths: [String]) async throws
}

extension VaultVersioning {
    func recordSnapshot(changing paths: [String]) async throws {
        try await recordSnapshot()
    }
}
