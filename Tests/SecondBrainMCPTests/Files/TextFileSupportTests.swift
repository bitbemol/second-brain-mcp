import Foundation
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

    @Test
    func `Records strict decoding and exact patch baselines`() throws {
        let data = Data(repeating: 0x61, count: 8 * 1024 * 1024)
        let strictDecode = try measure(iterations: 4) {
            _ = try TextFileSupport.string(from: data)
        }
        let preservingDecode = try measure(iterations: 4) {
            _ = try TextFileSupport.stringPreservingByteOrderMark(from: data)
        }

        let original = String(repeating: "a", count: 4 * 1024 * 1024) + "needle"
        let patch = [TextReplacement(oldText: "needle", newText: "target")]
        let exactPatch = try measure(iterations: 4) {
            _ = try TextFileSupport.apply(patch, to: original)
        }
        let singlePassPatch = try measure(iterations: 4) {
            var result = original
            let range = try #require(result.range(of: "needle"))
            #expect(result.range(of: "needle", range: range.upperBound..<result.endIndex) == nil)
            result.replaceSubrange(range, with: "target")
        }

        let appendOriginal = String(repeating: "a", count: 4 * 1024 * 1024)
        let appendContent = String(repeating: "b", count: 1024 * 1024)
        var exactAppendBytes = 0
        let exactAppend = measure(iterations: 20) {
            let result = TextFileSupport.appending(appendContent, to: appendOriginal)
            exactAppendBytes += result.utf8.count
        }
        var reservedAppendBytes = 0
        let reservedAppend = measure(iterations: 20) {
            let originalEndsLine = appendOriginal.last?.isNewline ?? false
            let contentStartsLine = appendContent.first?.isNewline ?? false
            var result = String()
            result.reserveCapacity(
                appendOriginal.utf8.count + appendContent.utf8.count
                    + (originalEndsLine || contentStartsLine ? 0 : 1)
            )
            result.append(appendOriginal)
            if !originalEndsLine && !contentStartsLine {
                result.append("\n")
            }
            result.append(appendContent)
            reservedAppendBytes += result.utf8.count
        }
        #expect(exactAppendBytes == reservedAppendBytes)

        let decodeRatio = millisecondsValue(preservingDecode)
            / millisecondsValue(strictDecode)
        let patchRatio = millisecondsValue(exactPatch)
            / millisecondsValue(singlePassPatch)
        let appendRatio = millisecondsValue(exactAppend)
            / millisecondsValue(reservedAppend)
        print(
            "TEXT_PIPELINE_BASELINE "
                + "strict_decode_ms=\(milliseconds(strictDecode)) "
                + "preserving_decode_ms=\(milliseconds(preservingDecode)) "
                + "decode_ratio=\(String(format: "%.3f", decodeRatio)) "
                + "exact_patch_ms=\(milliseconds(exactPatch)) "
                + "single_pass_patch_ms=\(milliseconds(singlePassPatch)) "
                + "patch_ratio=\(String(format: "%.3f", patchRatio)) "
                + "exact_append_ms=\(milliseconds(exactAppend)) "
                + "reserved_append_ms=\(milliseconds(reservedAppend)) "
                + "append_ratio=\(String(format: "%.3f", appendRatio))"
        )
        #expect(
            decodeRatio < 1.6,
            "BOM preservation performs substantially more than one strict decode"
        )
        #expect(
            patchRatio < 1.6,
            "Exact patching scans the document again after proving uniqueness"
        )
        #expect(
            appendRatio < 1.8,
            "Appending builds multiple full-size intermediate strings"
        )
    }

    private func measure(
        iterations: Int,
        samples: Int = 3,
        _ operation: () throws -> Void
    ) rethrows -> Duration {
        let clock = ContinuousClock()
        var best: Duration?
        for _ in 0..<samples {
            let start = clock.now
            for _ in 0..<iterations {
                try operation()
            }
            let elapsed = start.duration(to: clock.now)
            best = best.map { Swift.min($0, elapsed) } ?? elapsed
        }
        return best ?? .zero
    }

    private func milliseconds(_ duration: Duration) -> String {
        String(format: "%.3f", millisecondsValue(duration))
    }

    private func millisecondsValue(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
