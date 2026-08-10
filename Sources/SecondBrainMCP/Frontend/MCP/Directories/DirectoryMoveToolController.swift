import MCP

/// Strict MCP adapter for the standalone directory-move mutation.
struct DirectoryMoveToolController: Sendable {
    private let readOnly: Bool
    private let directories: any DirectoryMoveService

    init(
        readOnly: Bool,
        directories: any DirectoryMoveService
    ) {
        self.readOnly = readOnly
        self.directories = directories
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard params.name == DirectoryMoveToolDefinition.name else {
            return FileToolResultMapper.failure("Unknown tool: \(params.name)")
        }
        let values = params.arguments ?? [:]
        if readOnly {
            try Task.checkCancellation()
            return FileToolResultMapper.failure(
                "Server is running in read-only mode; 'move_directory' is not permitted."
            )
        }

        let request: MoveDirectoryRequest
        do {
            request = try Self.decode(values)
        } catch let error as DecodingError {
            return FileToolResultMapper.failure(error.description)
        }
        do {
            let output = try await directories.move(request)
            try Task.checkCancellation()
            return FileToolResultMapper.success(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return FileToolResultMapper.failure("Error: \(error)")
        }
    }

    private enum DecodingError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let value): value }
        }
    }

    private static func decode(_ values: [String: Value]) throws -> MoveDirectoryRequest {
        let allowed: Set<String> = ["mutation_id", "source_path", "destination_path"]
        guard values.keys.allSatisfy(allowed.contains) else {
            throw DecodingError.invalid("Directory move contains an unknown parameter")
        }
        let mutation = try requiredString("mutation_id", values: values)
        guard let mutationID = MutationID(rawValue: mutation) else {
            throw DecodingError.invalid("Invalid mutation_id: expected a UUID")
        }
        return MoveDirectoryRequest(
            mutationID: mutationID,
            sourcePath: try requiredString("source_path", values: values),
            destinationPath: try requiredString("destination_path", values: values)
        )
    }

    private static func requiredString(
        _ name: String,
        values: [String: Value]
    ) throws -> String {
        guard let value = values[name] else {
            throw DecodingError.invalid("Missing required parameter: \(name)")
        }
        guard let string = value.stringValue else {
            throw DecodingError.invalid("Invalid parameter '\(name)': expected string")
        }
        return string
    }
}
