/// Optional CRUD bindings registered for one concrete format.
///
/// A `nil` binding means the operation is unsupported and therefore omitted
/// from MCP schema and capability discovery.
struct FormatOperations: Sendable {
    /// Create behavior, when supported.
    let create: CreateOperationBinding?
    /// Read behavior, when supported.
    let read: ReadOperationBinding?
    /// Update behavior, when supported.
    let update: UpdateOperationBinding?
    /// Delete behavior, when supported.
    let delete: DeleteOperationBinding?

    /// Non-empty allowed areas keyed by each registered CRUD operation.
    var allowedAreasByOperation: [FileCRUDOperation: Set<VaultArea>] {
        let registrations: [FileCRUDOperation: Set<VaultArea>?] = [
            .create: create?.allowedAreas,
            .read: read?.allowedAreas,
            .update: update?.allowedAreas,
            .delete: delete?.allowedAreas,
        ]
        return registrations.compactMapValues { areas in
            guard let areas, !areas.isEmpty else { return nil }
            return areas
        }
    }
}
