/// Structural vault regions that participate in file-operation policy.
enum VaultArea: String, CaseIterable, Codable, Sendable {
    /// User-authored, Git-tracked content that may be writable.
    case notes
    /// Reference-library content that is read-only by construction.
    case references

    /// Resolves a vault-relative path to its structural area.
    ///
    /// - Parameter path: A path beginning with `notes/` or `references/`.
    /// - Returns: The matching vault area.
    /// - Throws: ``FileRoutingError/invalidArea(_:)`` for every other prefix.
    static func resolve(path: String) throws -> VaultArea {
        if path.hasPrefix("notes/") { return .notes }
        if path.hasPrefix("references/") { return .references }
        throw FileRoutingError.invalidArea(path)
    }
}
