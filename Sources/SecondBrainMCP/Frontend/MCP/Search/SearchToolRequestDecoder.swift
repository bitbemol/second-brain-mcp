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
        let allowed = Set(SearchToolArgument.allCases.map(\.rawValue))
        guard values.keys.allSatisfy(allowed.contains) else {
            throw DecodingError.invalid("Search request contains an unknown parameter")
        }
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
            fields: try enumArray(
                .fields,
                in: values,
                as: SearchField.self,
                maximumCount: SearchField.allCases.count
            ),
            formats: try enumArray(
                .formats,
                in: values,
                as: FileFormat.self,
                maximumCount: FileFormat.allCases.count
            ),
            pathPrefix: try string(.pathPrefix, in: values),
            limit: try integer(.limit, in: values)
                ?? SearchRequestLimits.defaultResults,
            minimumRelevance: try number(.minimumRelevance, in: values)
                ?? SearchRequestLimits.defaultMinimumRelevance
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

    private static func number(
        _ argument: SearchToolArgument,
        in values: [String: Value]
    ) throws -> Double? {
        guard let value = values[argument] else { return nil }
        let number: Double
        if let double = value.doubleValue {
            number = double
        } else if let integer = value.intValue {
            number = Double(integer)
        } else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected number"
            )
        }
        guard number.isFinite, (0...1).contains(number) else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected number from 0 through 1"
            )
        }
        return number
    }

    private static func enumArray<Element: RawRepresentable>(
        _ argument: SearchToolArgument,
        in values: [String: Value],
        as type: Element.Type,
        maximumCount: Int
    ) throws -> [Element]? where Element.RawValue == String {
        guard let value = values[argument] else { return nil }
        guard let array = value.arrayValue else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected array of strings"
            )
        }
        guard array.count <= maximumCount else {
            throw DecodingError.invalid(
                "Parameter '\(argument.rawValue)' contains too many values"
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
