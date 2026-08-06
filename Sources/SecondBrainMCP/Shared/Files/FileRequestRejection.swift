/// A file request rejected at the transport boundary before backend routing.
struct FileRequestRejection: Equatable, Sendable {
    /// Stable reasons a transport may reject an otherwise recognized operation.
    enum Reason: Equatable, Sendable {
        /// The process was started without mutation permissions.
        case readOnly
    }

    /// CRUD operation the client attempted.
    let operation: FileCRUDOperation
    /// Unvalidated path supplied by the client, when present.
    let path: String?
    /// Boundary policy responsible for the rejection.
    let reason: Reason
}

/// Transport-neutral sink for file requests rejected before backend routing.
protocol FileRequestRejectionReporting: Sendable {
    /// Records one rejected request without changing its transport response.
    ///
    /// - Parameter rejection: Operation, optional path, and rejection reason.
    func record(_ rejection: FileRequestRejection) async
}
