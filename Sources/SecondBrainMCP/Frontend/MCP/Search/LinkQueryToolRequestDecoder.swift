import MCP

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
        let groupBy: LinkQueryGrouping?
        if let rawGrouping = try string(.groupBy, in: values) {
            guard let parsed = LinkQueryGrouping(rawValue: rawGrouping) else {
                throw DecodingError(description: "group_by must be source or occurrence")
            }
            groupBy = parsed
        } else {
            groupBy = nil
        }
        return LinkQueryRequest(
            direction: direction,
            target: try requiredString(.target, in: values),
            fromPath: try string(.fromPath, in: values),
            groupBy: groupBy,
            sourcePath: try string(.sourcePath, in: values),
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
