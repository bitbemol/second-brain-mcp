import MCP

/// Strict typed access to raw MCP file-tool arguments.
///
/// Optional means absent, never malformed. A present value with the wrong JSON
/// type is rejected here before request defaults or backend semantics apply.
struct FileToolArguments: Sendable {
    /// Failures raised while converting raw MCP values to expected argument types.
    enum ValidationError: Error, CustomStringConvertible, Sendable {
        /// A required argument is absent.
        case missingRequired(FileToolArgument)
        /// A present argument has the wrong JSON type.
        case invalidType(argument: FileToolArgument, expected: String)

        /// Human-readable boundary validation failure.
        var description: String {
            switch self {
            case .missingRequired(let argument):
                "Missing required parameter: \(argument.rawValue)"
            case .invalidType(let argument, let expected):
                "Invalid parameter '\(argument.rawValue)': expected \(expected)"
            }
        }
    }

    private let values: [String: Value]

    /// Captures the raw argument object from one MCP tool call.
    init(_ params: CallTool.Parameters) {
        self.values = params.arguments ?? [:]
    }

    /// Returns an optional string, rejecting a present non-string value.
    func string(_ argument: FileToolArgument) throws -> String? {
        try value(argument, expected: "string", using: \.stringValue)
    }

    /// Returns a required string, distinguishing absence from an invalid type.
    func requiredString(_ argument: FileToolArgument) throws -> String {
        guard let value = try string(argument) else {
            throw ValidationError.missingRequired(argument)
        }
        return value
    }

    /// Returns an optional integer, rejecting a present non-integer value.
    func integer(_ argument: FileToolArgument) throws -> Int? {
        try value(argument, expected: "integer", using: \.intValue)
    }

    /// Returns an optional Boolean, rejecting a present non-Boolean value.
    func boolean(_ argument: FileToolArgument) throws -> Bool? {
        try value(argument, expected: "boolean", using: \.boolValue)
    }

    /// Returns an optional array, rejecting a present non-array value.
    func array(_ argument: FileToolArgument) throws -> [Value]? {
        try value(argument, expected: "array", using: \.arrayValue)
    }

    /// Returns an optional string array without dropping malformed elements.
    func stringArray(_ argument: FileToolArgument) throws -> [String]? {
        try value(argument, expected: "array of strings") { raw in
            guard let elements = raw.arrayValue else { return nil }
            let strings = elements.compactMap(\.stringValue)
            return strings.count == elements.count ? strings : nil
        }
    }

    private func value<Result>(
        _ argument: FileToolArgument,
        expected: String,
        using conversion: (Value) -> Result?
    ) throws -> Result? {
        guard let raw = values[argument] else { return nil }
        guard let converted = conversion(raw) else {
            throw ValidationError.invalidType(
                argument: argument,
                expected: expected
            )
        }
        return converted
    }
}
