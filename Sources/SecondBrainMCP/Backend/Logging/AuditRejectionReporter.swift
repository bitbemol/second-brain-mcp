/// Adapts transport-neutral file rejections to the backend audit log.
struct AuditRejectionReporter: FileRequestRejectionReporting, Sendable {
    private let audit: AuditLogger

    /// Creates a rejection reporter backed by one vault's audit logger.
    ///
    /// - Parameter audit: Append-only backend audit sink.
    init(audit: AuditLogger) {
        self.audit = audit
    }

    /// Translates a rejected CRUD request into the existing audit vocabulary.
    ///
    /// - Parameter rejection: Transport-neutral rejection event.
    func record(_ rejection: FileRequestRejection) async {
        await audit.log(
            operation: rejection.operation,
            path: rejection.path,
            details: rejection.auditDetails
        )
    }
}

private extension FileRequestRejection {
    var auditDetails: String {
        switch reason {
        case .readOnly:
            "\(operation.rawValue)_file rejected: read-only"
        }
    }
}
