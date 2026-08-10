import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `HAR inspection` {
    @Test
    func `Every entry requires the fields used by HAR summaries`() throws {
        #expect(throws: HARInspector.InspectionError.self) {
            try HARInspector.inspect(data: Data(#"""
        {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[
          {"request":{"method":42,"url":"https://example.com/a"},
           "response":{"status":"200"},"time":"slow"},
          {"request":{"method":"POST","url":"https://api.example.com/b"},
           "response":{"status":201},"time":12.5}
        ]}}
        """#.utf8))
        }

        #expect(throws: HARInspector.InspectionError.self) {
            try HARInspector.inspect(data: Data(#"""
            {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[{}]}}
            """#.utf8))
        }
    }

    @Test
    func `Entry timing and status values have safe numeric domains`() {
        #expect(throws: HARInspector.InspectionError.self) {
            try HARInspector.inspect(data: Data(#"""
            {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[
              {"request":{"method":"GET","url":"https://example.com"},
               "response":{"status":-1},"time":1}
            ]}}
            """#.utf8))
        }

        #expect(throws: HARInspector.InspectionError.self) {
            try HARInspector.inspect(data: Data(#"""
            {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[
              {"request":{"method":"GET","url":"https://example.com"},
               "response":{"status":200},"time":1e308},
              {"request":{"method":"GET","url":"https://example.com"},
               "response":{"status":200},"time":1e308}
            ]}}
            """#.utf8))
        }
    }

    @Test
    func `Request URLs are absolute and host counting is case-insensitive`() throws {
        #expect(throws: HARInspector.InspectionError.self) {
            try HARInspector.inspect(data: Data(#"""
            {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[
              {"request":{"method":"GET","url":"not a URL"},
               "response":{"status":200},"time":1}
            ]}}
            """#.utf8))
        }

        let inspection = try HARInspector.inspect(data: Data(#"""
        {"log":{"version":"1.2","creator":{"name":"Browser"},"entries":[
          {"request":{"method":"GET","url":"https://EXAMPLE.com/a"},
           "response":{"status":200},"time":1},
          {"request":{"method":"GET","url":"https://example.com/b"},
           "response":{"status":200},"time":1}
        ]}}
        """#.utf8))

        #expect(inspection.hostCount == 1)
    }

    @Test
    func `Invalid JSON and missing required structure remain distinct`() {
        #expect(throws: HARInspector.InspectionError.self) {
            try HARInspector.inspect(data: Data("not json".utf8))
        }

        do {
            _ = try HARInspector.inspect(data: Data("{}".utf8))
            Issue.record("Expected a missing log error")
        } catch HARInspector.InspectionError.invalidStructure(let reason) {
            #expect(reason == "missing top-level log object")
        } catch {
            Issue.record("Expected HARInspector.InspectionError.invalidStructure, got \(error)")
        }
    }
}
