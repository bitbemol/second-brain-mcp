import Foundation

/// Scans text one line at a time without materializing an array for the document.
enum TextLineScanner {
    /// A bounded line selection plus whole-document counts.
    struct Window: Sendable {
        /// Selected lines, never exceeding the requested maximum.
        let lines: [String]
        /// Total logical records; a final delimiter terminates its record.
        let totalLineCount: Int
        /// One-based first selected line, or `nil` for an empty out-of-range window.
        let firstLine: Int?
        /// One-based final selected line, or `nil` for an empty out-of-range window.
        let lastLine: Int?
    }

    /// Counts records without allocating one `String` per line; empty text has none.
    static func lineCount(in text: String) -> Int {
        // The empty cancellation check cannot throw.
        try! lineCount(in: text, cancellationCheck: {})
    }

    /// Counts logical lines while cooperatively observing cancellation.
    static func lineCount(
        in text: String,
        cancellationCheck: () throws -> Void
    ) throws -> Int {
        var count = 0
        try scanLines(in: text, cancellationCheck: cancellationCheck) { _, _ in
            count += 1
        }
        return count
    }

    /// Selects at most `maximumLines` beginning at a one-based line number.
    static func window(
        in text: String,
        startingAt requestedStart: Int,
        maximumLines: Int
    ) -> Window {
        // The empty cancellation check cannot throw.
        try! window(
            in: text,
            startingAt: requestedStart,
            maximumLines: maximumLines,
            cancellationCheck: {}
        )
    }

    /// Selects a bounded line window while cooperatively observing cancellation.
    static func window(
        in text: String,
        startingAt requestedStart: Int,
        maximumLines: Int,
        cancellationCheck: () throws -> Void
    ) throws -> Window {
        let total = try lineCount(
            in: text,
            cancellationCheck: cancellationCheck
        )
        return try window(
            in: text,
            startingAt: requestedStart,
            maximumLines: maximumLines,
            totalLineCount: total,
            cancellationCheck: cancellationCheck
        )
    }

    private static func window(
        in text: String,
        startingAt requestedStart: Int,
        maximumLines: Int,
        totalLineCount: Int,
        cancellationCheck: () throws -> Void
    ) throws -> Window {
        let start = min(max(requestedStart, 1), totalLineCount + 1)
        let limit = max(maximumLines, 0)
        var selected: [String] = []
        selected.reserveCapacity(min(limit, totalLineCount))

        try scanLines(in: text, cancellationCheck: cancellationCheck) { line, lineNumber in
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
        // The empty cancellation check cannot throw.
        try! tail(
            in: text,
            maximumLines: maximumLines,
            cancellationCheck: {}
        )
    }

    /// Selects a bounded tail while cooperatively observing cancellation.
    static func tail(
        in text: String,
        maximumLines: Int,
        cancellationCheck: () throws -> Void
    ) throws -> Window {
        let total = try lineCount(
            in: text,
            cancellationCheck: cancellationCheck
        )
        let count = min(max(maximumLines, 0), total)
        return try window(
            in: text,
            startingAt: total - count + 1,
            maximumLines: count,
            totalLineCount: total,
            cancellationCheck: cancellationCheck
        )
    }

    /// Visits logical lines as Unicode-scalar slices, retaining no line collection.
    static func forEachLine(
        in text: String,
        _ body: (String.UnicodeScalarView.SubSequence, Int) -> Void
    ) {
        // The empty cancellation check cannot throw.
        try! scanLines(in: text, cancellationCheck: {}, body)
    }

    /// Performs one cooperative, allocation-bounded line traversal.
    private static func scanLines(
        in text: String,
        cancellationCheck: () throws -> Void,
        _ body: (String.UnicodeScalarView.SubSequence, Int) -> Void
    ) throws {
        try cancellationCheck()
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var lineNumber = 1
        var scalarCountSinceCancellation = 0

        var index = scalars.startIndex
        while index < scalars.endIndex {
            scalarCountSinceCancellation += 1
            if scalarCountSinceCancellation == 4_096 {
                try cancellationCheck()
                scalarCountSinceCancellation = 0
            }

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
        try cancellationCheck()
        // Delimiters already emitted their records, including intentional blanks.
        // Only an unterminated final record remains; empty text has no records.
        if start < scalars.endIndex {
            body(scalars[start..<scalars.endIndex], lineNumber)
        }
    }
}
