import Foundation

/// Scans text one line at a time without materializing an array for the document.
enum TextLineScanner {
    /// A bounded line selection plus whole-document counts.
    struct Window: Sendable {
        /// Selected lines, never exceeding the requested maximum.
        let lines: [String]
        /// Total logical lines in the source, including a trailing empty line.
        let totalLineCount: Int
        /// One-based first selected line, or `nil` for an empty out-of-range window.
        let firstLine: Int?
        /// One-based final selected line, or `nil` for an empty out-of-range window.
        let lastLine: Int?
    }

    /// Counts newline-delimited components without allocating one `String` per line.
    static func lineCount(in text: String) -> Int {
        var count = 0
        forEachLine(in: text) { _, _ in count += 1 }
        return count
    }

    /// Selects at most `maximumLines` beginning at a one-based line number.
    static func window(
        in text: String,
        startingAt requestedStart: Int,
        maximumLines: Int
    ) -> Window {
        let total = lineCount(in: text)
        return window(
            in: text,
            startingAt: requestedStart,
            maximumLines: maximumLines,
            totalLineCount: total
        )
    }

    private static func window(
        in text: String,
        startingAt requestedStart: Int,
        maximumLines: Int,
        totalLineCount: Int
    ) -> Window {
        let start = min(max(requestedStart, 1), totalLineCount + 1)
        let limit = max(maximumLines, 0)
        var selected: [String] = []
        selected.reserveCapacity(min(limit, totalLineCount))

        forEachLine(in: text) { line, lineNumber in
            guard lineNumber >= start, selected.count < limit else { return }
            selected.append(String(line))
        }
        return Window(
            lines: selected,
            totalLineCount: totalLineCount,
            firstLine: selected.isEmpty ? nil : start,
            lastLine: selected.isEmpty ? nil : start + selected.count - 1
        )
    }

    /// Selects at most the requested number of lines from the document end.
    static func tail(in text: String, maximumLines: Int) -> Window {
        let total = lineCount(in: text)
        let count = min(max(maximumLines, 0), total)
        return window(
            in: text,
            startingAt: total - count + 1,
            maximumLines: count,
            totalLineCount: total
        )
    }

    /// Visits logical lines as Unicode-scalar slices, retaining no line collection.
    static func forEachLine(
        in text: String,
        _ body: (String.UnicodeScalarView.SubSequence, Int) -> Void
    ) {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var lineNumber = 1

        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard CharacterSet.newlines.contains(scalar) else {
                index = scalars.index(after: index)
                continue
            }

            body(scalars[start..<index], lineNumber)
            var next = scalars.index(after: index)
            // CRLF is one logical delimiter. Treating each scalar separately
            // inserts a phantom empty line into Windows-authored logs.
            if scalar == "\r",
               next < scalars.endIndex,
               scalars[next] == "\n" {
                next = scalars.index(after: next)
            }
            start = next
            index = next
            lineNumber += 1
        }
        body(scalars[start..<scalars.endIndex], lineNumber)
    }
}
