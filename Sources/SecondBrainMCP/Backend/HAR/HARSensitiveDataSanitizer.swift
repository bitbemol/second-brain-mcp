import Foundation

/// Removes well-known HTTP credentials from a HAR before it enters Git history.
///
/// HAR is evidence rather than an opaque byte-preservation format. Re-encoding
/// is deliberate: unknown JSON fields remain present, while sensitive headers,
/// cookies, authentication query parameters, URL user information, and form
/// parameters are replaced with an explicit marker. A later general text scan
/// rejects credentials in unrecognized locations instead of silently storing them.
enum HARSensitiveDataSanitizer {
    /// Sanitized archive bytes and the number of replaced values.
    struct Result: Sendable {
        /// Strict JSON ready for HAR semantic validation and persistence.
        let data: Data
        /// Number of values replaced with ``redactionMarker``.
        let redactionCount: Int
    }

    /// Input is not one strict, unambiguous JSON object that can represent a HAR.
    struct InvalidJSON: Error, Sendable {}

    /// A search-specific structured-value ceiling was exhausted.
    struct ResourceLimit: Error, Sendable {}

    /// Public marker used in sanitized archives and tests.
    static let redactionMarker = "[REDACTED]"

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
        "x-access-token",
    ]

    private static let normalizedSensitiveParameterNames: Set<String> = [
        "accesstoken",
        "authtoken",
        "apikey",
        "clientsecret",
        "csrftoken",
        "idtoken",
        "passcode",
        "passwd",
        "password",
        "refreshtoken",
        "session",
        "sessionid",
        "sessiontoken",
        "token",
    ]

    /// Sanitizes known credential-bearing HAR fields without dropping extensions.
    ///
    /// Duplicate object keys are refused before Foundation materializes the
    /// document because otherwise one duplicate would be silently discarded.
    /// Arbitrary valid JSON number spellings are temporarily represented by
    /// unique strings and restored after sanitization, preserving unknown HAR
    /// extensions such as values outside `Double`'s range.
    static func sanitize(
        _ data: Data,
        maximumValueCount: Int? = nil
    ) throws -> Result {
        let outerValueCount: Int
        do {
            outerValueCount = try JSONSyntaxValidator.validate(
                data,
                rejectingDuplicateObjectKeys: true,
                maximumValueCount: maximumValueCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch JSONSyntaxValidator.ValidationError.excessiveValueCount {
            throw ResourceLimit()
        } catch JSONSyntaxValidator.ValidationError.excessiveNesting
            where maximumValueCount != nil {
            throw ResourceLimit()
        } catch {
            throw InvalidJSON()
        }
        try Task.checkCancellation()

        let preserved: PreservedNumbers
        let object: Any
        do {
            preserved = preserveNumbers(in: data)
            try Task.checkCancellation()
            object = try JSONSerialization.jsonObject(with: preserved.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InvalidJSON()
        }
        guard var root = object as? [String: Any] else {
            throw InvalidJSON()
        }

        var redactions = 0
        var remainingNestedValues = maximumValueCount.map {
            max($0 - outerValueCount, 0)
        }
        if var log = root["log"] as? [String: Any],
           let rawEntries = log["entries"] as? [Any] {
            log["entries"] = try rawEntries.map { rawEntry in
                try Task.checkCancellation()
                guard var entry = rawEntry as? [String: Any] else {
                    return rawEntry
                }
                if var request = entry["request"] as? [String: Any] {
                    redactions += sanitizeMessage(&request)
                    redactions += sanitizeParameters(
                        named: "queryString",
                        in: &request
                    )
                    redactions += try sanitizeRequestURL(
                        &request,
                        remainingValueCount: &remainingNestedValues
                    )
                    if var postData = request["postData"] as? [String: Any] {
                        redactions += sanitizeParameters(
                            named: "params",
                            in: &postData
                        )
                        redactions += try sanitizePostDataText(
                            &postData,
                            remainingValueCount: &remainingNestedValues
                        )
                        request["postData"] = postData
                    }
                    entry["request"] = request
                }
                if var response = entry["response"] as? [String: Any] {
                    redactions += sanitizeMessage(&response)
                    entry["response"] = response
                }
                return entry
            }
            root["log"] = log
        }

        // Browser extensions sometimes store header or parameter arrays outside
        // the standard HAR locations. Recognize every name/value tuple while
        // retaining its enclosing extension structure.
        try Task.checkCancellation()
        let nested = sanitizeNamedValuePairs(root)
        try Task.checkCancellation()
        guard let sanitizedRoot = nested.value as? [String: Any] else {
            throw InvalidJSON()
        }
        redactions += nested.redactions

        do {
            let encoded = try JSONSerialization.data(
                withJSONObject: sanitizedRoot,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let sanitized = try preserved.restoringNumbers(in: encoded)
            try JSONSyntaxValidator.validate(
                sanitized,
                rejectingDuplicateObjectKeys: true,
                maximumValueCount: maximumValueCount
            )
            return Result(data: sanitized, redactionCount: redactions)
        } catch is CancellationError {
            throw CancellationError()
        } catch JSONSyntaxValidator.ValidationError.excessiveValueCount {
            throw ResourceLimit()
        } catch {
            throw InvalidJSON()
        }
    }

    private static func sanitizeMessage(
        _ message: inout [String: Any]
    ) -> Int {
        var redactions = 0
        if let rawHeaders = message["headers"] as? [Any] {
            message["headers"] = rawHeaders.map { rawHeader in
                guard var header = rawHeader as? [String: Any],
                      let name = header["name"] as? String,
                      sensitiveHeaderNames.contains(normalizedHeaderName(name)) else {
                    return rawHeader
                }
                redactions += redactValue(in: &header)
                return header
            }
        }
        if let rawCookies = message["cookies"] as? [Any] {
            message["cookies"] = rawCookies.map { rawCookie in
                guard var cookie = rawCookie as? [String: Any] else {
                    return rawCookie
                }
                redactions += redactValue(in: &cookie)
                return cookie
            }
        }
        return redactions
    }

    private static func sanitizeParameters(
        named field: String,
        in container: inout [String: Any]
    ) -> Int {
        guard let rawParameters = container[field] as? [Any] else { return 0 }
        var redactions = 0
        container[field] = rawParameters.map { rawParameter in
            guard var parameter = rawParameter as? [String: Any],
                  let name = parameter["name"] as? String,
                  isSensitiveParameter(name) else {
                return rawParameter
            }
            redactions += redactValue(in: &parameter)
            return parameter
        }
        return redactions
    }

    private static func sanitizeRequestURL(
        _ request: inout [String: Any],
        remainingValueCount: inout Int?
    ) throws -> Int {
        guard let rawURL = request["url"] as? String,
              var components = URLComponents(string: rawURL) else { return 0 }

        var redactions = 0
        if components.user != nil {
            components.user = nil
            redactions += 1
        }
        if components.password != nil {
            components.password = nil
            redactions += 1
        }
        if let query = components.percentEncodedQuery {
            let sanitized = try sanitizePercentEncodedQuery(
                query,
                remainingValueCount: &remainingValueCount
            )
            components.percentEncodedQuery = sanitized.text
            redactions += sanitized.redactions
        }
        if redactions > 0, let sanitizedURL = components.string {
            request["url"] = sanitizedURL
        }
        return redactions
    }

    /// Sanitizes credential fields carried in common textual request bodies.
    private static func sanitizePostDataText(
        _ postData: inout [String: Any],
        remainingValueCount: inout Int?
    ) throws -> Int {
        guard let text = postData["text"] as? String,
              let rawMIMEType = postData["mimeType"] as? String else { return 0 }
        let mimeType = rawMIMEType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if mimeType == "application/json" || mimeType.hasSuffix("+json") {
            let source = Data(text.utf8)
            do {
                let embeddedValueCount = try JSONSyntaxValidator.validate(
                    source,
                    rejectingDuplicateObjectKeys: true,
                    maximumValueCount: remainingValueCount
                )
                if remainingValueCount != nil {
                    remainingValueCount = max(
                        (remainingValueCount ?? 0) - embeddedValueCount,
                        0
                    )
                }
                let preserved = preserveNumbers(in: source)
                let object = try JSONSerialization.jsonObject(
                    with: preserved.data,
                    options: [.fragmentsAllowed]
                )
                let keyed = sanitizeSensitiveObjectKeys(object)
                let named = sanitizeNamedValuePairs(keyed.value)
                let encoded = try JSONSerialization.data(
                    withJSONObject: named.value,
                    options: [
                        .fragmentsAllowed,
                        .sortedKeys,
                        .withoutEscapingSlashes,
                    ]
                )
                let sanitized = try preserved.restoringNumbers(in: encoded)
                guard let sanitizedText = String(
                    data: sanitized,
                    encoding: .utf8
                ) else {
                    throw InvalidJSON()
                }
                postData["text"] = sanitizedText
                return keyed.redactions + named.redactions
            } catch is CancellationError {
                throw CancellationError()
            } catch JSONSyntaxValidator.ValidationError.excessiveValueCount {
                throw ResourceLimit()
            } catch JSONSyntaxValidator.ValidationError.excessiveNesting
                where remainingValueCount != nil {
                throw ResourceLimit()
            } catch {
                throw InvalidJSON()
            }
        }

        if mimeType == "application/x-www-form-urlencoded" {
            let sanitized = try sanitizePercentEncodedQuery(
                text,
                remainingValueCount: &remainingValueCount
            )
            if sanitized.redactions > 0 {
                postData["text"] = sanitized.text
            }
            return sanitized.redactions
        }
        return 0
    }

    /// Redacts one query representation incrementally and charges every pair to
    /// the caller's remaining structured-value budget before materialization.
    private static func sanitizePercentEncodedQuery(
        _ query: String,
        remainingValueCount: inout Int?
    ) throws -> (text: String, redactions: Int) {
        guard !query.isEmpty else { return ("", 0) }
        var output = ""
        output.reserveCapacity(query.utf8.count)
        var redactions = 0
        var start = query.startIndex
        var index = 0

        while start <= query.endIndex {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            index += 1
            if let remaining = remainingValueCount {
                guard remaining > 0 else { throw ResourceLimit() }
                remainingValueCount = remaining - 1
            }
            let separator = query[start...].firstIndex(of: "&") ?? query.endIndex
            let component = query[start..<separator]
            let equals = component.firstIndex(of: "=")
            let rawName = equals.map { component[..<$0] } ?? component[...]
            let rawValue = equals.map { component[component.index(after: $0)...] }
            let decodedName = String(rawName).removingPercentEncoding
                ?? String(rawName)

            if index > 1 { output.append("&") }
            if isSensitiveParameter(decodedName), let rawValue {
                let decodedValue = String(rawValue).removingPercentEncoding
                    ?? String(rawValue)
                output.append(contentsOf: rawName)
                output.append("=%5BREDACTED%5D")
                if decodedValue != redactionMarker { redactions += 1 }
            } else {
                output.append(contentsOf: component)
            }
            guard separator < query.endIndex else { break }
            start = query.index(after: separator)
        }
        return (output, redactions)
    }

    private static func sanitizeSensitiveObjectKeys(
        _ value: Any
    ) -> (value: Any, redactions: Int) {
        if var object = value as? [String: Any] {
            var redactions = 0
            for (key, child) in object {
                if isSensitiveName(key), !(child is NSNull) {
                    if let child = child as? String, child == redactionMarker {
                        continue
                    }
                    object[key] = redactionMarker
                    redactions += 1
                } else {
                    let nested = sanitizeSensitiveObjectKeys(child)
                    object[key] = nested.value
                    redactions += nested.redactions
                }
            }
            return (object, redactions)
        }
        if let array = value as? [Any] {
            var redactions = 0
            let sanitized = array.map { child in
                let nested = sanitizeSensitiveObjectKeys(child)
                redactions += nested.redactions
                return nested.value
            }
            return (sanitized, redactions)
        }
        return (value, 0)
    }

    private static func sanitizeNamedValuePairs(
        _ value: Any
    ) -> (value: Any, redactions: Int) {
        if var object = value as? [String: Any] {
            var redactions = 0
            if let name = object["name"] as? String,
               isSensitiveName(name) {
                redactions += redactValue(in: &object)
            }
            for (key, child) in object {
                let nested = sanitizeNamedValuePairs(child)
                object[key] = nested.value
                redactions += nested.redactions
            }
            return (object, redactions)
        }
        if let array = value as? [Any] {
            var redactions = 0
            let sanitized = array.map { child in
                let nested = sanitizeNamedValuePairs(child)
                redactions += nested.redactions
                return nested.value
            }
            return (sanitized, redactions)
        }
        return (value, 0)
    }

    private static func redactValue(in object: inout [String: Any]) -> Int {
        guard let value = object["value"], !(value is NSNull) else { return 0 }
        if let value = value as? String, value == redactionMarker { return 0 }
        object["value"] = redactionMarker
        return 1
    }

    private static func isSensitiveName(_ name: String) -> Bool {
        sensitiveHeaderNames.contains(normalizedHeaderName(name))
            || isSensitiveParameter(name)
    }

    private static func normalizedHeaderName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isSensitiveParameter(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalizedSensitiveParameterNames.contains(normalized)
    }

    /// JSONSerialization cannot represent finite JSON numbers outside Double's
    /// range. Masking only lexical number tokens lets it transform the enclosing
    /// object without narrowing or rewriting unknown extension values.
    private static func preserveNumbers(in data: Data) -> PreservedNumbers {
        let bytes = Array(data)
        var prefix = "__SECOND_BRAIN_NUMBER_\(UUID().uuidString)_"
        while data.range(of: Data(prefix.utf8)) != nil {
            prefix += "_"
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var values: [String] = []
        var index = 0
        var insideString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if insideString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    insideString = false
                }
                index += 1
                continue
            }
            if byte == 0x22 {
                insideString = true
                output.append(byte)
                index += 1
                continue
            }
            if byte == 0x2d || (0x30...0x39).contains(byte) {
                let start = index
                index += 1
                while index < bytes.count,
                      (0x30...0x39).contains(bytes[index])
                        || [0x2b, 0x2d, 0x2e, 0x45, 0x65].contains(bytes[index]) {
                    index += 1
                }
                values.append(String(decoding: bytes[start..<index], as: UTF8.self))
                output.append(0x22)
                output.append(contentsOf: "\(prefix)\(values.count - 1)".utf8)
                output.append(0x22)
                continue
            }
            output.append(byte)
            index += 1
        }
        return PreservedNumbers(data: Data(output), prefix: prefix, values: values)
    }

    private struct PreservedNumbers {
        let data: Data
        let prefix: String
        let values: [String]

        func restoringNumbers(in data: Data) throws -> Data {
            guard let text = String(data: data, encoding: .utf8) else {
                throw InvalidJSON()
            }
            let markerStart = "\"\(prefix)"
            var output = ""
            output.reserveCapacity(text.utf8.count)
            var cursor = text.startIndex

            while let start = text.range(
                of: markerStart,
                range: cursor..<text.endIndex
            ) {
                output.append(contentsOf: text[cursor..<start.lowerBound])
                guard let closingQuote = text[start.upperBound...]
                    .firstIndex(of: "\"") else {
                    throw InvalidJSON()
                }
                let indexText = text[start.upperBound..<closingQuote]
                guard let index = Int(indexText), values.indices.contains(index) else {
                    throw InvalidJSON()
                }
                output.append(values[index])
                cursor = text.index(after: closingQuote)
            }
            output.append(contentsOf: text[cursor...])
            return Data(output.utf8)
        }
    }
}
