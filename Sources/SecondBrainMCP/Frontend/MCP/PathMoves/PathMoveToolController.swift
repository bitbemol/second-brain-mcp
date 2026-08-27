import MCP

/// Strict MCP adapter for the standalone atomic path-move mutation.
struct PathMoveToolController: Sendable {
    private let readOnly: Bool
    private let paths: any PathMoveService

    init(
        readOnly: Bool,
        paths: any PathMoveService
    ) {
        self.readOnly = readOnly
        self.paths = paths
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard params.name == PathMoveToolDefinition.name else {
            return ToolFailureProjection.rejected("Unknown tool: choose a tool returned by tools/list")
        }
        let values = params.arguments ?? [:]
        if readOnly {
            try Task.checkCancellation()
            return ToolFailureProjection.rejected(
                "Server is running in read-only mode; 'move_path' is not permitted."
            )
        }

        let request: MovePathRequest
        do {
            request = try Self.decode(values)
        } catch let error as DecodingError {
            return ToolFailureProjection.rejected(error.description)
        }
        do {
            let output = try await paths.move(request)
            try Task.checkCancellation()
            return FileToolResultMapper.pathMoveSuccess(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return ToolFailureProjection.operation(
                error, state: .unknown,
                fallback: "Path move failed due to an internal error"
            )
        }
    }


    private enum DecodingError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let value): value }
        }
    }

    private static func decode(_ values: [String: Value]) throws -> MovePathRequest {
        let allowed: Set<String> = [
            "kind", "source_path", "destination_path", "format", "expected_revision",
        ]
        guard values.keys.allSatisfy(allowed.contains) else {
            throw DecodingError.invalid("Path move contains an unknown parameter")
        }
        let kindValue = try requiredString("kind", values: values)
        guard let kind = PathMoveKind(rawValue: kindValue) else {
            throw DecodingError.invalid(
                "Invalid parameter 'kind': expected file or directory"
            )
        }
        let sourcePath = try requiredString("source_path", values: values)
        let destinationPath = try requiredString("destination_path", values: values)
        switch kind {
        case .directory:
            guard values["format"] == nil, values["expected_revision"] == nil else {
                throw DecodingError.invalid(
                    "Directory moves do not accept format or expected_revision"
                )
            }
            return .directory(
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        case .file:
            let formatValue = try requiredString("format", values: values)
            guard let format = FileFormat(rawValue: formatValue) else {
                throw DecodingError.invalid(
                    "Invalid parameter 'format': unsupported concrete format"
                )
            }
            let revisionValue = try requiredString("expected_revision", values: values)
            guard let revision = FileRevision(rawValue: revisionValue) else {
                throw DecodingError.invalid(
                    "Invalid parameter 'expected_revision': expected canonical sha256 revision"
                )
            }
            return .file(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                format: format,
                expectedRevision: revision
            )
        }
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
