//
//  VaultVersioning.swift
//  SecondBrainMCP
//
//  Created by BitBemol on 09/08/26.
//

/// Records recoverable states of a notes vault without exposing the underlying
/// version-control implementation.
///
/// A conforming type snapshots state rather than individual agent activity.
/// Concurrent requests may be represented by one shared snapshot when that
/// snapshot already contains every caller's changes.
protocol VaultVersioning: Sendable {
    /// Records the current vault state if it differs from the latest snapshot.
    ///
    /// Returning normally means the state is recoverable. It does not guarantee
    /// that this particular call created a new version.
    func recordSnapshot() async throws
}
