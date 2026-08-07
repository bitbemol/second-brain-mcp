import MCP

/// Strictly decodes the public search arguments into a shared request.
enum SearchToolRequestDecoder {
    enum DecodingError: Error, CustomStringConvertible, Sendable {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    static func decode(_ params: CallTool.Parameters) throws -> VaultSearchRequest {
        let values = params.arguments ?? [:]
        let query = try requiredString(.query, in: values)

        let strategy: SearchStrategy
        if let raw = try string(.strategy, in: values) {
            guard let parsed = SearchStrategy(rawValue: raw) else {
                throw DecodingError.invalid("Unsupported search strategy")
            }
            strategy = parsed
        } else {
            strategy = .smart
        }

        return VaultSearchRequest(
            query: query,
            strategy: strategy,
            fields: try enumArray(.fields, in: values, as: SearchField.self),
            formats: try enumArray(.formats, in: values, as: FileFormat.self),
            pathPrefix: try string(.pathPrefix, in: values),
            limit: try integer(.limit, in: values)
                ?? SearchRequestLimits.defaultResults
        )
    }

    private static func requiredString(
        _ argument: SearchToolArgument,
        in values: [String: Value]
    ) throws -> String {
        guard let value = values[argument] else {
            throw DecodingError.invalid(
                "Missing required parameter: \(argument.rawValue)"
            )
        }
        guard let string = value.stringValue else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected string"
            )
        }
        return string
    }

    private static func string(
        _ argument: SearchToolArgument,
        in values: [String: Value]
    ) throws -> String? {
        guard let value = values[argument] else { return nil }
        guard let string = value.stringValue else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected string"
            )
        }
        return string
    }

    private static func integer(
        _ argument: SearchToolArgument,
        in values: [String: Value]
    ) throws -> Int? {
        guard let value = values[argument] else { return nil }
        guard let integer = value.intValue else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected integer"
            )
        }
        return integer
    }

    private static func enumArray<Element: RawRepresentable>(
        _ argument: SearchToolArgument,
        in values: [String: Value],
        as type: Element.Type
    ) throws -> [Element]? where Element.RawValue == String {
        guard let value = values[argument] else { return nil }
        guard let array = value.arrayValue else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected array of strings"
            )
        }
        var decoded: [Element] = []
        for item in array {
            guard let raw = item.stringValue, let element = Element(rawValue: raw) else {
                throw DecodingError.invalid(
                    "Invalid value in '\(argument.rawValue)'"
                )
            }
            decoded.append(element)
        }
        return decoded
    }
}
