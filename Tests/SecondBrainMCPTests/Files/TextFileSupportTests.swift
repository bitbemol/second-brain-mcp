import Testing
@testable import second_brain_mcp

@Suite
struct `Shared text file support` {
    @Test
    func `Appending inserts only a missing line boundary`() {
        #expect(TextFileSupport.appending("first", to: "") == "first")
        #expect(TextFileSupport.appending("", to: "first") == "first")
        #expect(TextFileSupport.appending("second", to: "first") == "first\nsecond")
        #expect(TextFileSupport.appending("second", to: "first\n") == "first\nsecond")
        #expect(TextFileSupport.appending("\nsecond", to: "first") == "first\nsecond")
        #expect(TextFileSupport.appending("second", to: "first\r") == "first\rsecond")
    }

    @Test
    func `Empty patch targets are rejected before exact-match scanning`() {
        do {
            _ = try TextFileSupport.apply(
                [TextReplacement(oldText: "", newText: "injected")],
                to: "original"
            )
            Issue.record("Expected an empty patch target to be rejected")
        } catch let error as TextFileSupport.TextError {
            guard case .emptyPatchTarget(let index) = error else {
                Issue.record("Unexpected text error: \(error)")
                return
            }
            #expect(index == 1)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func `Identity replacements still require an exact target`() {
        #expect(throws: TextFileSupport.TextError.self) {
            try TextFileSupport.apply(
                [TextReplacement(oldText: "missing", newText: "missing")],
                to: "original"
            )
        }
    }

    @Test
    func `Ordered replacements observe the preceding replacement`() throws {
        let result = try TextFileSupport.apply(
            [
                TextReplacement(oldText: "alpha", newText: "beta"),
                TextReplacement(oldText: "beta", newText: "gamma"),
            ],
            to: "alpha"
        )

        #expect(result == "gamma")
    }
}
