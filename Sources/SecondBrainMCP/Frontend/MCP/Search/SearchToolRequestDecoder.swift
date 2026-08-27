import MCP

enum SearchToolRequestDecoder {
    struct DecodingError: Error, CustomStringConvertible {
        let description: String
        static func invalid(_ message: String) -> DecodingError {
            DecodingError(description: message)
        }
    }

    static func decode(_ params: CallTool.Parameters) throws -> VaultSearchRequest {
        let values = params.arguments ?? [:]
        let known = Set(SearchToolArgument.allCases.map(\.rawValue))
        guard values.keys.allSatisfy(known.contains) else {
            throw DecodingError.invalid("Search request contains an unknown parameter")
        }
        let rawLocation = try requiredString(.location, in: values)
        guard let location = VaultArea(rawValue: rawLocation) else {
            throw DecodingError.invalid("location must be notes or references")
        }
        return VaultSearchRequest(
            location: location,
            query: try string(.query, in: values),
            tags: try strings(.tags, in: values) ?? [],
            createdFrom: try string(.createdFrom, in: values),
            createdThrough: try string(.createdThrough, in: values),
            limit: try integer(.limit, in: values) ?? SearchRequestLimits.defaultResults,
            cursor: try string(.cursor, in: values)
        )
    }

    private static func requiredString(
        _ argument: SearchToolArgument,
        in values: [String: Value]
    ) throws -> String {
        guard let value = try string(argument, in: values) else {
            throw DecodingError.invalid("Missing required parameter: \(argument.rawValue)")
        }
        return value
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

    private static func strings(
        _ argument: SearchToolArgument,
        in values: [String: Value]
    ) throws -> [String]? {
        guard let value = values[argument] else { return nil }
        guard let array = value.arrayValue,
              array.count <= SearchRequestLimits.maximumTags else {
            throw DecodingError.invalid(
                "Invalid parameter '\(argument.rawValue)': expected a bounded array"
            )
        }
        return try array.map { item in
            guard let value = item.stringValue else {
                throw DecodingError.invalid(
                    "Invalid parameter '\(argument.rawValue)': expected strings"
                )
            }
            return value
        }
    }
}

enum LinkQueryToolRequestDecoder {
    struct DecodingError: Error, CustomStringConvertible {
        let description: String
    }

    static func decode(_ params: CallTool.Parameters) throws -> LinkQueryRequest {
        let values = params.arguments ?? [:]
        let known = Set(LinkQueryToolArgument.allCases.map(\.rawValue))
        if let unknown = values.keys.filter({ !known.contains($0) }).sorted().first {
            throw DecodingError(description: "Unknown parameter: \(unknown)")
        }
        let directionValue = try requiredString(.direction, in: values)
        guard let direction = LinkQueryDirection(rawValue: directionValue) else {
            throw DecodingError(
                description: "direction must be resolve, outgoing, or backlinks"
            )
        }
        return LinkQueryRequest(
            direction: direction,
            target: try requiredString(.target, in: values),
            fromPath: try string(.fromPath, in: values),
            limit: try integer(.limit, in: values) ?? LinkQueryLimits.defaultResults,
            cursor: try string(.cursor, in: values)
        )
    }

    private static func requiredString(
        _ argument: LinkQueryToolArgument,
        in values: [String: Value]
    ) throws -> String {
        guard let value = try string(argument, in: values) else {
            throw DecodingError(
                description: "Missing required parameter: \(argument.rawValue)"
            )
        }
        return value
    }

    private static func string(
        _ argument: LinkQueryToolArgument,
        in values: [String: Value]
    ) throws -> String? {
        guard let value = values[argument.rawValue] else { return nil }
        guard let string = value.stringValue else {
            throw DecodingError(
                description: "Invalid parameter '\(argument.rawValue)': expected string"
            )
        }
        return string
    }

    private static func integer(
        _ argument: LinkQueryToolArgument,
        in values: [String: Value]
    ) throws -> Int? {
        guard let value = values[argument.rawValue] else { return nil }
        guard let integer = value.intValue else {
            throw DecodingError(
                description: "Invalid parameter '\(argument.rawValue)': expected integer"
            )
        }
        return integer
    }
}
