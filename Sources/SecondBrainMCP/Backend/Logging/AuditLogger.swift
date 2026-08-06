import Foundation

/// Append-only structured log of every operation.
/// Actor because concurrent writes to the log file must be serialized.
actor AuditLogger {
    private let logURL: URL
    private let maximumBytes: Int
    private let retainedFiles: Int
    private let processLock: POSIXAdvisoryFileLock?

    /// Creates an audit logger in an already prepared process-data directory.
    ///
    /// - Parameters:
    ///   - dataDirectory: Process storage prepared during bootstrap.
    ///   - maximumBytes: Size at which the active log rotates before appending.
    ///   - retainedFiles: Number of rotated logs retained beside the active file.
    ///   - coordinateAcrossProcesses: Whether independent MCP processes should
    ///     serialize rotation and append through a shared advisory lock.
    init(
        dataDirectory: VaultDataDirectory,
        maximumBytes: Int = 5 * 1024 * 1024,
        retainedFiles: Int = 3,
        coordinateAcrossProcesses: Bool = false
    ) {
        self.logURL = dataDirectory.auditLogURL
        self.maximumBytes = max(maximumBytes, 1)
        self.retainedFiles = max(retainedFiles, 0)
        self.processLock = coordinateAcrossProcesses
            ? POSIXAdvisoryFileLock(
                url: dataDirectory.lockDirectoryURL
                    .appendingPathComponent("audit.lock")
            )
            : nil
    }

    /// Appends an operation with optional path and routing details.
    ///
    /// - Parameters:
    ///   - operation: Transport-neutral CRUD operation to record.
    ///   - area: Vault area used to distinguish reference reads.
    ///   - path: Optional vault-relative request path.
    ///   - details: Optional handler or rejection context.
    ///
    /// Logging is best-effort: file-system failures do not fail the user operation.
    func log(
        operation: FileCRUDOperation,
        area: VaultArea = .notes,
        path: String? = nil,
        details: String? = nil
    ) async {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let entry = AuditLogEntry(
            timestamp: timestamp,
            operation: operation,
            area: area,
            path: path,
            details: details
        ).line

        guard let data = entry.data(using: .utf8) else { return }
        let append = { @Sendable in
            Self.append(
                data,
                to: self.logURL,
                maximumBytes: self.maximumBytes,
                retainedFiles: self.retainedFiles
            )
        }

        // Logging remains best-effort. Production coordinates the complete
        // rotate-and-append sequence across processes; tests may keep the
        // historical process-local behavior through the default initializer.
        if let processLock {
            try? await processLock.withLock(.exclusive, operation: append)
        } else {
            append()
        }
    }

    private static func append(
        _ data: Data,
        to logURL: URL,
        maximumBytes: Int,
        retainedFiles: Int
    ) {
        rotateIfNeeded(
            logURL: logURL,
            addingBytes: data.count,
            maximumBytes: maximumBytes,
            retainedFiles: retainedFiles
        )
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = FileHandle(forWritingAtPath: logURL.path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logURL.path, contents: data)
        }
    }

    /// Rotates bounded process-owned logs before the next append would exceed policy.
    private static func rotateIfNeeded(
        logURL: URL,
        addingBytes: Int,
        maximumBytes: Int,
        retainedFiles: Int
    ) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let currentBytes = attributes[.size] as? Int,
              currentBytes + addingBytes > maximumBytes else {
            return
        }

        if retainedFiles == 0 {
            try? fileManager.removeItem(at: logURL)
            return
        }
        for index in stride(from: retainedFiles, through: 1, by: -1) {
            let destination = rotatedURL(logURL: logURL, index: index)
            if index == retainedFiles,
               fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            let source = index == 1
                ? logURL
                : rotatedURL(logURL: logURL, index: index - 1)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    private static func rotatedURL(logURL: URL, index: Int) -> URL {
        URL(fileURLWithPath: logURL.path + ".\(index)")
    }
}
