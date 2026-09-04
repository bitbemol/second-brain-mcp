import MCP

/// Stable recovery metadata for file operations and listing. State comes from the
/// dispatch boundary, never from an error type that might also be thrown after persistence.
enum ToolFailureProjection {
    enum State: String {
        case notApplied = "not_applied"
        case readOnly = "read_only"
        case unknown
    }

    enum Code: String {
        case alreadyExists = "ALREADY_EXISTS"
        case notFound = "NOT_FOUND"
        case directoryNotFound = "DIRECTORY_NOT_FOUND"
        case invalidPath = "INVALID_PATH"
        case missingTransform = "MISSING_TRANSFORM"
        case invalidRequest = "INVALID_REQUEST"
        case revisionConflict = "REVISION_CONFLICT"
        case snapshotFailed = "SNAPSHOT_FAILED"
        case operationFailed = "OPERATION_FAILED"
        case internalError = "INTERNAL_ERROR"
    }

    static func rejected(_ message: String) -> CallTool.Result {
        failure(message, code: .invalidRequest, state: .notApplied)
    }

    /// Recovery gate failures happen before a mutation reaches persistence.
    static func recovery(
        _ message: String,
        attempt: Int,
        category: String
    ) -> CallTool.Result {
        failure(
            message,
            code: .snapshotFailed,
            state: .notApplied,
            retry: "retry_recovery",
            metadata: [
                "recovery_attempt": .int(attempt),
                "recovery_category": .string(category),
            ]
        )
    }

    static func operation(
        _ error: Error,
        state: State,
        fallback: String
    ) -> CallTool.Result {
        let projectedError: any Error
        let projectedState: State
        switch error {
        case MutationFailure.beforePersistence(let cause):
            projectedError = cause
            projectedState = .notApplied
        case MutationFailure.afterPersistenceStarted(let cause):
            projectedError = cause
            projectedState = .unknown
        default:
            projectedError = error
            projectedState = state
        }
        let message: String
        if let listingError = projectedError as? FileListingError {
            // Listing diagnostics contain fixed policy text, limits, and audited option names.
            message = listingError.description
        } else if let safe = projectedError as? any CallerSafeError {
            message = "Error: \(safe.callerSafeDescription)"
        } else {
            message = fallback
        }
        return failure(message, code: code(for: projectedError), state: projectedState)
    }

    private static func failure(
        _ message: String,
        code: Code,
        state: State,
        retry: String? = nil,
        metadata: [String: Value] = [:]
    ) -> CallTool.Result {
        let suffix = state == .unknown
            ? " Outcome unconfirmed; inspect current state before retrying."
            : ""
        let bounded = message.utf8.count + suffix.utf8.count <= ToolErrorResponse.maximumMessageBytes
            ? message + suffix
            : "Operation failed; diagnostic details exceed the safe response limit." + suffix
        var error: [String: Value] = [
            "code": .string(code.rawValue),
            "state": .string(state.rawValue),
            "retry": .string(
                retry ?? (state == .unknown ? "inspect_state" : "correct_request")
            ),
        ]
        error.merge(metadata) { current, _ in current }
        return CallTool.Result(
            content: [.text(text: bounded, annotations: nil, _meta: nil)],
            structuredContent: .object(["error": .object(error)]),
            isError: true
        )
    }

    private static func code(for error: Error) -> Code {
        switch error {
        case let error as VaultCRUDStore.StoreError:
            switch error {
            case .alreadyExists: .alreadyExists
            case .changedSinceRead: .revisionConflict
            case .unsafeTrashDirectory: .invalidPath
            }
        case let error as VaultFileInspector.InspectionError:
            switch error {
            case .notFound: .notFound
            case .notARegularFile: .invalidPath
            }
        case VaultSearchRequestError.directoryNotFound:
            .directoryNotFound
        case is HARInspector.InspectionError:
            .invalidRequest
        case is PathValidationError:
            .invalidPath
        case let error as CreateFileContractValidator.Violation:
            switch error {
            case .requiresTransform: .missingTransform
            default: .invalidRequest
            }
        case let error as FileListingError:
            switch error {
            case .directoryNotFound: .directoryNotFound
            case .invalidRequest, .invalidCursor: .invalidRequest
            case .staleCursor: .revisionConflict
            case .scanLimitExceeded: .operationFailed
            }
        case let error as FileRoutingError:
            switch error {
            case .revisionConflict: .revisionConflict
            case .invalidArea, .areaNotWritable, .extensionMismatch: .invalidPath
            default: .invalidRequest
            }
        case is VaultVersioningError:
            .snapshotFailed
        case is any CallerSafeError:
            .operationFailed
        default:
            .internalError
        }
    }
}
