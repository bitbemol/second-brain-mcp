import Foundation

/// Validates JSON Canvas creation and exact raw or selected-field reads.
struct CanvasFileOperations: Sendable {
    /// Validates the full immutable document before selecting decoded field bytes.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        try Task.checkCancellation()
        let options = request.options
        guard (options.canvasNodeID == nil) == (options.canvasField == nil) else {
            throw FileRoutingError.invalidReadOptions(
                "canvas_node_id and canvas_field must be supplied together"
            )
        }
        let document = try CanvasDocumentValidator.decodeValidated(jsonData: snapshot.data)
        let data: Data
        let selection: CanvasReadSelection?
        if let nodeID = options.canvasNodeID, let field = options.canvasField {
            guard let node = document.nodes.first(where: { $0.id == nodeID }) else {
                throw FileRoutingError.invalidReadOptions("Selected Canvas node does not exist")
            }
            guard let value = node.value(for: field) else {
                throw FileRoutingError.invalidReadOptions("Selected Canvas field is not present on this node")
            }
            data = Data(value.utf8)
            selection = CanvasReadSelection(nodeID: nodeID, field: field)
        } else {
            data = snapshot.data
            selection = nil
        }
        let chunk = try TextFileSupport.readChunk(
            from: data,
            byteOffset: options.byteOffset ?? 0,
            maximumBytes: options.maxBytes ?? FileReadRequestLimits.defaultTextChunkBytes
        )
        return .text(chunk.text, textWindow: chunk.window, canvasSelection: selection)
    }

    /// Validates a centrally loaded canvas payload before generic persistence.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        try CanvasDocumentValidator.validate(jsonData: input.data)
        return PreparedFileWrite(
            data: input.data,
            output: .text("Created \(target.relativePath)")
        )
    }
}
