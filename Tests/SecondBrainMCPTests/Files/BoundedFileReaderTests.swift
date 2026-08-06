import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Bounded file reader")
struct BoundedFileReaderTests {
    private func temporaryFile(containing data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BoundedFileReader-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test("Returns files exactly at the byte limit")
    func exactLimit() throws {
        let expected = Data(repeating: 0xAB, count: 128)
        let url = try temporaryFile(containing: expected)

        let actual = try BoundedFileReader.read(
            from: url,
            maximumBytes: expected.count,
            path: "notes/exact.bin"
        )

        #expect(actual == expected)
    }

    @Test("Stops after the first byte beyond the limit")
    func rejectsOverflowEarly() throws {
        let url = try temporaryFile(containing: Data(repeating: 0xCD, count: 1_000))

        do {
            _ = try BoundedFileReader.read(
                from: url,
                maximumBytes: 100,
                path: "notes/growing.bin"
            )
            Issue.record("Expected a file resource-policy violation")
        } catch let error as FileResourcePolicy.Violation {
            #expect(error.path == "notes/growing.bin")
            #expect(error.bytes == 101)
            #expect(error.limit == 100)
        } catch {
            Issue.record("Expected FileResourcePolicy.Violation, got \(error)")
        }
    }
}
