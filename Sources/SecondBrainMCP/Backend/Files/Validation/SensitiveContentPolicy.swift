import Foundation

/// Rejects high-confidence credentials before text reaches generic persistence.
///
/// The policy intentionally favors a small set of strong signals over broad
/// entropy guesses. This keeps ordinary prose, diffs, fixtures, and identifiers
/// usable while stopping credentials that would otherwise become permanent Git
/// history. Diagnostics identify only the detector and line; secret values are
/// never copied into errors, logs, or MCP responses.
enum SensitiveContentPolicy {
    /// A prepared text file contains a high-confidence credential.
    struct Violation: Error, CustomStringConvertible, Sendable {
        /// Vault-relative destination rejected by the policy.
        let path: String
        /// Stable, non-secret detector label.
        let detector: String
        /// One-based source line containing the match.
        let line: Int

        /// Safe diagnostic that never includes the matched value.
        var description: String {
            "Sensitive content rejected in \(path) at line \(line) "
                + "(\(detector)); replace the credential with a redacted placeholder"
        }
    }

    private struct Detector: Sendable {
        let label: String
        let pattern: String
        let permitsPlaceholder: Bool
        let requiresBearerCredentialShape: Bool
    }

    /// Fixed, linear regular expressions whose first capture is the candidate.
    private static let detectors: [Detector] = [
        Detector(
            label: "bearer credential",
            pattern: #"(?i)\bbearer[ \t]+([A-Za-z0-9._~+/=-]{20,})"#,
            permitsPlaceholder: true,
            requiresBearerCredentialShape: true
        ),
        Detector(
            label: "authorization header",
            pattern: #"(?i)\b(?:authorization|proxy-authorization)\b[\"']?\s*[:=]\s*[\"']?(?:(?:basic|digest|bearer)[ \t]+)?([A-Za-z0-9._~+/=-]{20,})"#,
            permitsPlaceholder: true,
            requiresBearerCredentialShape: false
        ),
        Detector(
            label: "token assignment",
            pattern: #"(?i)\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|session[_-]?token|api[_-]?key|client[_-]?secret|aws[_-]?secret[_-]?access[_-]?key)\b[\"']?\s*(?::|=)\s*[\"']?([A-Za-z0-9._~+/=-]{16,})"#,
            permitsPlaceholder: true,
            requiresBearerCredentialShape: false
        ),
        Detector(
            label: "URL user information",
            pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s/@:]+:([^\s/@]{12,})@"#,
            permitsPlaceholder: true,
            requiresBearerCredentialShape: false
        ),
        Detector(
            label: "URL password parameter",
            pattern: #"(?i)[?&](?:password|passwd)=([A-Za-z0-9._~%+/-]{12,})"#,
            permitsPlaceholder: true,
            requiresBearerCredentialShape: false
        ),
        Detector(
            label: "JSON web token",
            pattern: #"\b(eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,})\b"#,
            permitsPlaceholder: false,
            requiresBearerCredentialShape: false
        ),
        Detector(
            label: "provider API token",
            pattern: #"\b(sk-(?:proj-)?[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|AKIA[0-9A-Z]{16})\b"#,
            permitsPlaceholder: false,
            requiresBearerCredentialShape: false
        ),
        Detector(
            label: "private key",
            pattern: #"(-----BEGIN (?:ENCRYPTED |RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----)"#,
            permitsPlaceholder: false,
            requiresBearerCredentialShape: false
        ),
    ]

    private static let cookieAttributes: Set<String> = [
        "domain", "expires", "httponly", "max-age", "partitioned", "path",
        "samesite", "secure",
    ]

    private static let normalizedSensitiveURLParameterNames: Set<String> = [
        "accesstoken", "authtoken", "apikey", "clientsecret", "idtoken",
        "passwd", "password", "refreshtoken", "sessiontoken", "token",
    ]

    /// Validates prepared bytes for every Git-tracked textual format.
    ///
    /// Binary media and read-only PDF references are excluded because applying
    /// text heuristics to encoded bytes would create false positives without a
    /// meaningful security boundary.
    static func validate(
        _ data: Data,
        format: FileFormat,
        path: String
    ) throws {
        guard scans(format) else { return }
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: format,
            path: path
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw TextFileSupport.TextError.invalidUTF8
        }

        var representations = [text]
        if format == .json || format == .canvas || format == .har {
            // Credentials can be hidden by JSON Unicode escapes, or by another
            // JSON document embedded inside a JSON string. Decode a small,
            // bounded number of representation layers in addition to scanning
            // the exact source bytes. No object graph or numeric value is built.
            var decoded = text
            for _ in 0..<3 {
                let next = decodingJSONEscapes(in: decoded)
                guard next != decoded else { break }
                representations.append(next)
                decoded = next
            }
        }

        for representation in representations {
            try Task.checkCancellation()
            try validateDetectors(in: representation, path: path)
            try Task.checkCancellation()
            try validateURLCredentials(in: representation, path: path)
            try Task.checkCancellation()
            try validateCookieHeaders(in: representation, path: path)
        }
    }

    /// Decodes URL components so percent-encoded sensitive parameter names
    /// cannot bypass the raw high-confidence regular expressions.
    private static func validateURLCredentials(
        in text: String,
        path: String
    ) throws {
        let expression = try NSRegularExpression(
            pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#
        )
        try forEachMatch(of: expression, in: text) { match in
            guard let matchRange = Range(match.range, in: text),
                  let components = URLComponents(
                      string: String(text[matchRange])
                  ) else { return }
            if let password = components.password,
               password.count >= 12,
               !isPlaceholder(password) {
                throw Violation(
                    path: path,
                    detector: "URL user information",
                    line: lineNumber(in: text, before: matchRange.lowerBound)
                )
            }
            if let query = components.percentEncodedQuery {
                try validateURLQuery(
                    query,
                    in: text,
                    at: matchRange.lowerBound,
                    path: path
                )
            }
        }
    }

    /// Scans one percent-encoded query incrementally without materializing a
    /// caller-sized `[URLQueryItem]` object graph.
    private static func validateURLQuery(
        _ query: String,
        in text: String,
        at location: String.Index,
        path: String
    ) throws {
        var start = query.startIndex
        var visited = 0
        while start <= query.endIndex {
            if visited.isMultiple(of: 1_024) { try Task.checkCancellation() }
            visited += 1
            let separator = query[start...].firstIndex(of: "&") ?? query.endIndex
            let component = query[start..<separator]
            let equals = component.firstIndex(of: "=")
            let rawName = equals.map { component[..<$0] } ?? component[...]
            let rawValue = equals.map { component[component.index(after: $0)...] }
            let name = (String(rawName).removingPercentEncoding ?? String(rawName))
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            if normalizedSensitiveURLParameterNames.contains(name),
               let rawValue {
                let value = String(rawValue).removingPercentEncoding
                    ?? String(rawValue)
                let minimumLength = name == "password" || name == "passwd"
                    ? 12 : 16
                if value.count >= minimumLength, !isPlaceholder(value) {
                    throw Violation(
                        path: path,
                        detector: name == "password" || name == "passwd"
                            ? "URL password parameter" : "token assignment",
                        line: lineNumber(in: text, before: location)
                    )
                }
            }
            guard separator < query.endIndex else { break }
            start = query.index(after: separator)
        }
    }

    /// Iterates matches one at a time so dense input cannot allocate an array of
    /// every `NSTextCheckingResult` before cancellation is observed.
    private static func forEachMatch(
        of expression: NSRegularExpression,
        in text: String,
        _ body: (NSTextCheckingResult) throws -> Void
    ) throws {
        let completeRange = NSRange(text.startIndex..., in: text)
        var location = completeRange.location
        let end = completeRange.location + completeRange.length
        while location < end {
            try Task.checkCancellation()
            let range = NSRange(location: location, length: end - location)
            guard let match = expression.firstMatch(in: text, range: range) else {
                break
            }
            try body(match)
            location = min(
                match.range.location + max(match.range.length, 1),
                end
            )
        }
    }

    private static func validateDetectors(
        in text: String,
        path: String
    ) throws {
        for detector in detectors {
            try Task.checkCancellation()
            let expression = try NSRegularExpression(pattern: detector.pattern)
            let completeRange = NSRange(text.startIndex..., in: text)
            var searchLocation = completeRange.location
            let searchEnd = completeRange.location + completeRange.length

            while searchLocation < searchEnd {
                let searchRange = NSRange(
                    location: searchLocation,
                    length: searchEnd - searchLocation
                )
                guard let match = expression.firstMatch(
                    in: text,
                    range: searchRange
                ) else { break }
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: text) else {
                    break
                }
                let candidate = String(text[valueRange])
                if detector.requiresBearerCredentialShape,
                   !looksLikeBearerCredential(candidate) {
                    let next = match.range.location + max(match.range.length, 1)
                    searchLocation = min(next, searchEnd)
                    continue
                }
                if !detector.permitsPlaceholder || !isPlaceholder(candidate) {
                    throw Violation(
                        path: path,
                        detector: detector.label,
                        line: lineNumber(in: text, before: valueRange.lowerBound)
                    )
                }

                let next = match.range.location + max(match.range.length, 1)
                searchLocation = min(next, searchEnd)
            }
        }
    }

    /// Distinguishes opaque bearer values from ordinary hyphenated terminology.
    private static func looksLikeBearerCredential(_ candidate: String) -> Bool {
        candidate.count >= 28 || candidate.unicodeScalars.contains {
            $0.properties.numericType != nil || "._~+/=".unicodeScalars.contains($0)
        }
    }

    /// Examines each cookie pair independently so one placeholder cannot exempt
    /// a real credential later in the same header.
    private static func validateCookieHeaders(
        in text: String,
        path: String
    ) throws {
        let expression = try NSRegularExpression(
            pattern: #"(?i)\b(?:cookie|set-cookie)\b\s*[:=]\s*([^\r\n]+)"#
        )
        try forEachMatch(of: expression, in: text) { match in
            guard let headerRange = Range(match.range(at: 1), in: text) else {
                return
            }
            try validateCookieValue(
                text[headerRange],
                in: text,
                at: headerRange.lowerBound,
                path: path
            )
        }

        // JSON and Canvas spell the header name as a quoted member key. Capture
        // exactly its JSON string value so a minified following member is never
        // mistaken for part of the cookie.
        let jsonExpression = try NSRegularExpression(
            pattern: #"(?i)\"(?:cookie|set-cookie)\"\s*:\s*\"((?:\\.|[^\"\\])*)\""#
        )
        try forEachMatch(of: jsonExpression, in: text) { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else {
                return
            }
            try validateCookieValue(
                text[valueRange],
                in: text,
                at: valueRange.lowerBound,
                path: path
            )
        }
    }

    private static func validateCookieValue(
        _ header: Substring,
        in text: String,
        at location: String.Index,
        path: String
    ) throws {
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !cookieAttributes.contains(name) else { continue }
            let value = pair[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            guard value.count >= 20, !isPlaceholder(value) else { continue }
            throw Violation(
                path: path,
                detector: "session cookie",
                line: lineNumber(in: text, before: location)
            )
        }
    }

    private static func scans(_ format: FileFormat) -> Bool {
        format.isTextual
    }

    /// Recognizes only complete, conspicuous documentation values.
    private static func isPlaceholder(_ candidate: String) -> Bool {
        let value = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if (value.hasPrefix("${") && value.hasSuffix("}"))
            || (value.hasPrefix("<") && value.hasSuffix(">")) {
            return true
        }
        if !value.isEmpty && value.allSatisfy({ $0 == "x" || $0 == "_" }) {
            return true
        }
        let words = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = words.first,
              ["redacted", "placeholder", "example", "sample", "dummy", "changeme", "yourtoken"]
                .contains(String(first)) else {
            return false
        }
        let permittedSuffixes: Set<String> = [
            "api", "credential", "key", "password", "secret", "session", "token", "value",
        ]
        return words.dropFirst().allSatisfy {
            permittedSuffixes.contains(String($0))
        }
    }

    /// Decodes JSON escape spellings without materializing the JSON value.
    private static func decodingJSONEscapes(in text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index].value == 0x5c, index + 1 < scalars.count else {
                result.append(scalars[index])
                index += 1
                continue
            }
            let escaped = scalars[index + 1]
            switch escaped.value {
            case 0x22, 0x2f, 0x5c:
                result.append(escaped)
                index += 2
            case 0x62, 0x66, 0x6e, 0x72, 0x74:
                result.append(" ")
                index += 2
            case 0x75 where index + 5 < scalars.count:
                let digits = scalars[(index + 2)...(index + 5)]
                let spelling = String(String.UnicodeScalarView(digits))
                if let value = UInt32(spelling, radix: 16),
                   let scalar = UnicodeScalar(value),
                   !(0xd800...0xdfff).contains(value) {
                    result.append(CharacterSet.newlines.contains(scalar) ? " " : scalar)
                    index += 6
                } else {
                    result.append(scalars[index])
                    index += 1
                }
            default:
                result.append(scalars[index])
                index += 1
            }
        }
        return String(result)
    }

    /// Counts CR, LF, and CRLF as one logical line delimiter.
    private static func lineNumber(
        in text: String,
        before end: String.Index
    ) -> Int {
        var line = 1
        var previousWasCarriageReturn = false
        for scalar in text[..<end].unicodeScalars {
            switch scalar.value {
            case 0x0d:
                line += 1
                previousWasCarriageReturn = true
            case 0x0a:
                if !previousWasCarriageReturn { line += 1 }
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
        }
        return line
    }
}
