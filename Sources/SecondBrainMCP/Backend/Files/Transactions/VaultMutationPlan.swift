/// Metadata required to persist and snapshot one prepared vault mutation.
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
    }

    /// Mutation category used for persistence and recovery behavior.
    let kind: Kind
    /// Concrete file format selected by the validated target.
    let format: FileFormat
    /// Validated vault-relative target path.
    let path: String
    /// Validated target retained for exact post-persistence recovery checks.
    let target: WritableFileTarget
    /// Caller identity included in durable retry metadata.
    let mutationID: MutationID

    /// Creates transaction metadata from the exact target being mutated.
    ///
    /// Deriving format and path from `target` prevents recovery metadata from
    /// diverging from the persistence closure's destination.
    ///
    /// - Parameters:
    ///   - kind: Mutation category used for persistence and recovery behavior.
    ///   - target: Structurally writable target passed to persistence.
    ///   - mutationID: Caller identity used for durable retry handling.
    init(
        kind: Kind,
        target: WritableFileTarget,
        mutationID: MutationID
    ) {
        self.kind = kind
        self.format = target.format
        self.path = target.relativePath
        self.target = target
        self.mutationID = mutationID
    }
}
