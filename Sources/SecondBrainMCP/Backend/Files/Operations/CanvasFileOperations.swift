import Foundation

/// Validates, summarizes, and prepares JSON Canvas files for generic persistence.
///
/// Canvas-specific code owns structural validation and human-readable read output;
/// `VaultFileService` and the storage adapter continue to own routing and persistence.
struct CanvasFileOperations: Sendable {
    private let vaultPath: String

    /// Creates a canvas handler for files rooted in the supplied vault.
    ///
    /// - Parameter vaultPath: Absolute vault root used to verify file-node references.
    init(vaultPath: String) {
        self.vaultPath = vaultPath
    }

    /// Validates a centrally loaded canvas payload before generic persistence.
    ///
    /// - Parameters:
    ///   - input: Centrally validated canvas bytes.
    ///   - target: Validated destination used in the operation result.
    /// - Returns: Structurally valid canvas bytes ready for persistence.
    /// - Throws: ``CanvasDocumentValidator/ValidationError`` when JSON Canvas
    ///   invariants fail.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        try CanvasDocumentValidator.validate(jsonData: input.data)
        return PreparedFileWrite(data: input.data, output: .text("Created \(target.relativePath)"))
    }

    /// Returns a node-and-edge summary followed by validated snapshot JSON.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        let inspection = try CanvasDocumentValidator.inspect(jsonData: snapshot.data)
        let raw = try TextFileSupport.string(from: snapshot.data)
        return .text(summary(inspection: inspection, raw: raw, path: target.relativePath))
    }

    /// Validates replacement JSON before the generic compare-and-swap update.
    ///
    /// Canvas files deliberately support replacement only; append and text patch
    /// modes cannot preserve the format's structural invariants.
    func prepareUpdate(
        _ request: UpdateFileRequest,
        target: WritableFileTarget,
        snapshot: FileSnapshot
    ) throws -> PreparedFileWrite {
        guard request.mode == .replace else {
            throw FileRoutingError.operationNotSupported(format: .canvas, operation: .update, area: .notes)
        }
        guard let content = request.content else { throw TextFileSupport.TextError.missingContent }
        let data = Data(content.utf8)
        try CanvasDocumentValidator.validate(jsonData: data)
        return PreparedFileWrite(data: data, output: .text("Updated \(target.relativePath)"))
    }

    private func summary(
        inspection: CanvasInspection,
        raw: String,
        path: String
    ) -> String {
        var lines = [
            "\(path): \(inspection.nodes.count) node(s), "
                + "\(inspection.edgeCount) edge(s)"
        ]
        for node in inspection.nodes {
            var line = "- [\(node.kind.rawValue)] \(node.id)"
                + (node.label.isEmpty ? "" : " — \(node.label)")
            if let file = node.filePath, fileNodeIsMissing(file) {
                line += " ⚠ file not found"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n\n" + raw
    }

    private func fileNodeIsMissing(_ relativePath: String) -> Bool {
        guard let resolved = try? PathValidator.resolve(relativePath: relativePath, root: vaultPath) else {
            return true
        }
        return !FileManager.default.fileExists(atPath: resolved)
    }
}
