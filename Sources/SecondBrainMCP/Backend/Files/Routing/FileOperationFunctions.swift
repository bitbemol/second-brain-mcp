import Foundation

/// A format-specific create function that validates or transforms input bytes.
///
/// The function must not persist the returned data.
typealias CreateFileFunction = @Sendable (CreateFileRequest, WritableFileTarget) async throws -> PreparedFileWrite

/// A stored-text create resolver that receives centrally validated input.
///
/// The resolver owns format semantics only; routing has already rejected
/// external sources, required inline content, and enforced its resource limit.
typealias StoredTextCreateResolver = @Sendable (TextFileCreateInput, WritableFileTarget) throws -> PreparedFileWrite

/// A format-specific read function that interprets the service's one immutable snapshot.
typealias ReadFileFunction = @Sendable (
    ReadFileRequest,
    ReadableFileTarget,
    FileSnapshot
) async throws -> FileOperationOutput

/// A persistence-free read resolver that interprets a generic file snapshot.
typealias StoredReadResolver = @Sendable (ReadFileRequest, ReadableFileTarget, FileSnapshot) throws -> FileOperationOutput

/// Optional structural validation shared by generic text reads and updates.
typealias StoredTextValidator = @Sendable (Data, String) throws -> Void

/// Optional format-specific append joining used by the generic text update engine.
typealias StoredTextAppender = @Sendable (String, String) -> String

/// A format-specific update function that prepares replacement bytes from a snapshot.
///
/// The function must not persist the returned data.
typealias UpdateFileFunction = @Sendable (UpdateFileRequest, WritableFileTarget, FileSnapshot) async throws -> PreparedFileWrite

/// A format-specific validation or authorization hook for soft deletion.
typealias DeleteFileFunction = @Sendable (DeleteFileRequest, WritableFileTarget) async throws -> Void
