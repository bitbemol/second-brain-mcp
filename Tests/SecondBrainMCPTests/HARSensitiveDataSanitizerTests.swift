import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("HAR sensitive-data sanitization")
struct HARSensitiveDataSanitizerTests {
    @Test("Known HAR credential fields are redacted and extensions survive")
    func sanitizesKnownFields() throws {
        let bearer = "Bearer " + String(repeating: "a", count: 32)
        let cookie = "session=" + String(repeating: "b", count: 32)
        let queryToken = String(repeating: "c", count: 32)
        let formSecret = String(repeating: "d", count: 32)
        let responseCookie = "sid=" + String(repeating: "e", count: 32)
        let archive = """
        {
          "log": {
            "version": "1.2",
            "creator": {"name": "Browser"},
            "extension": {"preserve": true},
            "entries": [{
              "request": {
                "method": "POST",
                "url": "https://example.com/login?access_token=\(queryToken)&page=1",
                "headers": [
                  {"name": "Authorization", "value": "\(bearer)"},
                  {"name": "Cookie", "value": "\(cookie)"},
                  {"name": "X-Trace", "value": "trace-safe"}
                ],
                "cookies": [{"name": "session", "value": "\(cookie)"}],
                "queryString": [
                  {"name": "access_token", "value": "\(queryToken)"},
                  {"name": "page", "value": "1"}
                ],
                "postData": {"params": [
                  {"name": "client_secret", "value": "\(formSecret)"}
                ]}
              },
              "response": {
                "status": 200,
                "headers": [{"name": "Set-Cookie", "value": "\(responseCookie)"}],
                "cookies": [{"name": "sid", "value": "\(responseCookie)"}]
              },
              "time": 12
            }]
          }
        }
        """

        let result = try HARSensitiveDataSanitizer.sanitize(Data(archive.utf8))
        let text = try #require(String(data: result.data, encoding: .utf8))

        #expect(result.redactionCount == 8)
        for secret in [bearer, cookie, queryToken, formSecret, responseCookie] {
            #expect(!text.contains(secret))
        }
        #expect(text.contains(HARSensitiveDataSanitizer.redactionMarker))
        #expect(text.contains("trace-safe"))
        #expect(text.contains("\"preserve\":true"))
        #expect(try HARInspector.inspect(data: result.data).entryCount == 1)
        try SensitiveContentPolicy.validate(
            result.data,
            format: .har,
            path: "notes/login.har"
        )
    }

    @Test("Malformed and trailing-comma JSON is rejected")
    func rejectsInvalidJSON() {
        #expect(throws: HARSensitiveDataSanitizer.InvalidJSON.self) {
            try HARSensitiveDataSanitizer.sanitize(
                Data(#"{"log":{"entries":[],}}"#.utf8)
            )
        }
    }

    @Test("URL credentials, parameter aliases, and extension tuples are redacted")
    func sanitizesExpandedContexts() throws {
        let secret = String(repeating: "q", count: 32)
        let archive = """
        {
          "log": {
            "version": "1.2",
            "creator": {"name": "Browser"},
            "entries": [{
              "request": {
                "method": "POST",
                "url": "https://user:\(secret)@example.com/?password=\(secret)",
                "headers": [],
                "cookies": [],
                "queryString": [
                  {"name": "authToken", "value": "\(secret)"},
                  {"name": "session", "value": "\(secret)"}
                ],
                "postData": {"params": [
                  {"name": "passwd", "value": "\(secret)"}
                ]},
                "_extension": {"headers": [
                  {"name": " Authorization ", "value": "\(secret)"}
                ]}
              },
              "response": {"status": 200, "headers": [], "cookies": []},
              "time": 1
            }]
          }
        }
        """

        let result = try HARSensitiveDataSanitizer.sanitize(Data(archive.utf8))
        let text = try #require(String(data: result.data, encoding: .utf8))

        #expect(result.redactionCount >= 6)
        #expect(!text.contains(secret))
        #expect(!text.contains("user:"))
        #expect(text.contains(HARSensitiveDataSanitizer.redactionMarker))
        #expect(try HARInspector.inspect(data: result.data).entryCount == 1)
    }

    @Test("Duplicate object keys are rejected before materialization")
    func rejectsDuplicateKeys() {
        let archive = #"{"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[{"request":{"method":"GET","url":"https://example.com","headers":[{"name":"X-Trace","name":"Authorization","value":"secret-value-that-must-not-survive"}]},"response":{"status":200},"time":1}]}}"#

        #expect(throws: HARSensitiveDataSanitizer.InvalidJSON.self) {
            try HARSensitiveDataSanitizer.sanitize(Data(archive.utf8))
        }

        let escapedEquivalent = #"{"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[],"name":1,"n\u0061me":2}}"#
        #expect(throws: HARSensitiveDataSanitizer.InvalidJSON.self) {
            try HARSensitiveDataSanitizer.sanitize(
                Data(escapedEquivalent.utf8)
            )
        }
    }

    @Test("Unknown arbitrary-range numbers survive sanitization")
    func preservesArbitraryRangeNumbers() throws {
        let archive = #"{"log":{"version":"1.2","creator":{"name":"Browser"},"extension":{"huge":1e400,"exact":123456789012345678901234567890},"entries":[]}}"#

        let result = try HARSensitiveDataSanitizer.sanitize(Data(archive.utf8))
        let text = try #require(String(data: result.data, encoding: .utf8))

        #expect(text.contains("1e400"))
        #expect(text.contains("123456789012345678901234567890"))
        #expect(try HARInspector.inspect(data: result.data).entryCount == 0)
    }

    @Test("Escaped credentials inside embedded JSON remain subject to fallback scanning")
    func embeddedJSONCannotBypassFallbackPolicy() throws {
        let escaped = String(repeating: "\\u0073", count: 32)
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[{
          "request":{"method":"POST","url":"https://example.com","postData":{
            "text":"{\\\"access_token\\\":\\\"\(escaped)\\\"}"
          }},
          "response":{"status":200},"time":1
        }]}}
        """
        let result = try HARSensitiveDataSanitizer.sanitize(Data(archive.utf8))

        #expect(throws: SensitiveContentPolicy.Violation.self) {
            try SensitiveContentPolicy.validate(
                result.data,
                format: .har,
                path: "notes/embedded.har"
            )
        }
    }

    @Test("Number-heavy archives restore preserved spellings in one bounded pass")
    func restoresManyNumbersEfficiently() throws {
        let values = (0..<10_000).map(String.init).joined(separator: ",")
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Browser"},
        "extension":{"values":[\(values)]},"entries":[]}}
        """
        let clock = ContinuousClock()
        let start = clock.now

        let result = try HARSensitiveDataSanitizer.sanitize(Data(archive.utf8))

        #expect(clock.now - start < .seconds(2))
        let text = try #require(String(data: result.data, encoding: .utf8))
        #expect(text.contains("9999"))
    }

    @Test("JSON and form request bodies redact password fields")
    func sanitizesTextRequestBodies() throws {
        let secret = String(repeating: "w", count: 32)
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[
          {"request":{"method":"POST","url":"https://example.com/json",
            "postData":{"mimeType":"application/json; charset=utf-8",
              "text":"{\\\"password\\\":\\\"\(secret)\\\",\\\"safe\\\":1e400}"}},
           "response":{"status":200},"time":1},
          {"request":{"method":"POST","url":"https://example.com/form",
            "postData":{"mimeType":"application/x-www-form-urlencoded",
              "text":"username=user&password=\(secret)&safe=1"}},
           "response":{"status":200},"time":1}
        ]}}
        """

        let result = try HARSensitiveDataSanitizer.sanitize(Data(archive.utf8))
        let text = try #require(String(data: result.data, encoding: .utf8))

        #expect(result.redactionCount == 2)
        #expect(!text.contains(secret))
        #expect(text.contains("1e400"))
        #expect(try HARInspector.inspect(data: result.data).entryCount == 2)
    }

    @Test("Cancellation is never converted into an invalid-JSON diagnosis")
    func cancellationPropagates() async {
        let archive = Data(
            #"{"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[]}}"#.utf8
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try HARSensitiveDataSanitizer.sanitize(archive)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
