/// Metadata required to commit and audit one prepared vault mutation.
///
/// The plan contains no storage behavior. ``VaultFileService`` supplies the
/// concrete persistence closure after its format handler prepares the mutation.
struct VaultMutationPlan: Sendable {
    /// Mutating operations supported by the generic file API.
    enum Kind: Sendable {
        /// Create a new first-class file.
        case create
        /// Replace an existing first-class file.
        case update
        /// Move an existing first-class file into recoverable trash.
        case delete

        /// Transport-neutral file operation corresponding to the mutation.
        var fileOperation: FileCRUDOperation {
            switch self {
            case .create: .create
            case .update: .update
            case .delete: .delete
            }
        }

        /// Past-tense verb used in the stable Git commit message.
        var commitVerb: String {
            switch self {
            case .create: "Created"
            case .update: "Updated"
            case .delete: "Deleted"
            }
        }
    }

    /// Mutation category used for Git and audit behavior.
    let kind: Kind
    /// Concrete file format selected by the validated target.
    let format: FileFormat
    /// Validated vault-relative target path.
    let path: String
    /// Validated target retained for commit-only recovery state checks.
    let target: WritableFileTarget
    /// Format handler that prepared or authorized the mutation.
    let handler: FileHandlerID
    /// Caller identity included in commit metadata for retry diagnostics.
    let mutationID: MutationID

    /// Stable Git message carrying the required replay identity.
    var commitMessage: String {
        "[SecondBrainMCP] \(kind.commitVerb) \(format.rawValue): \(path)"
    }

    /// Stable audit context shared by normal execution and recovery.
    var auditDetails: String {
        return "\(handler.rawValue); mutation_id=\(mutationID.rawValue)"
    }

    /// Creates transaction metadata from the exact target being mutated.
    ///
    /// Deriving format and path from `target` prevents commit and audit metadata
    /// from diverging from the persistence closure's destination.
    ///
    /// - Parameters:
    ///   - kind: Mutation category used for Git and audit behavior.
    ///   - target: Structurally writable target passed to persistence.
    ///   - handler: Format handler that prepared or authorized the mutation.
    ///   - mutationID: Caller identity used for durable retry handling.
    init(
        kind: Kind,
        target: WritableFileTarget,
        handler: FileHandlerID,
        mutationID: MutationID
    ) {
        self.kind = kind
        self.format = target.format
        self.path = target.relativePath
        self.target = target
        self.handler = handler
        self.mutationID = mutationID
    }
}
