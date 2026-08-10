import Foundation

/// Implements bounded reads and append-only updates for UTF-8 log files.
///
/// Log reads default to the final 500 lines and cap caller-selected windows at
/// 5,000 lines. Updates accept append mode only, preserving the chronological
/// history expected from this semantic file type.
struct LogFileOperations: Sendable {
    /// Describes centrally loaded UTF-8 log bytes before generic persistence.
    ///
    /// - Parameters:
    ///   - input: Centrally validated log bytes.
    ///   - target: Validated destination included in the creation result.
    /// - Returns: Log bytes and their initial line-count summary.
    /// - Throws: ``TextFileSupport/TextError`` when bytes are not valid UTF-8.
    func prepareCreate(
        _ input: TextFileCreateInput,
        target: WritableFileTarget
    ) throws -> PreparedFileWrite {
        let lineCount = TextLineScanner.lineCount(
            in: try TextFileSupport.string(from: input.data)
        )
        return PreparedFileWrite(data: input.data, output: .text("Created \(target.relativePath) (\(lineCount) lines)"))
    }

    /// Reads a bounded line window from a supplied log snapshot.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        let text = try TextFileSupport.string(from: snapshot.data)

        let window: TextLineScanner.Window
        let description: String
        if let tail = request.options.tailLines {
            let count = min(max(tail, 1), 5_000)
            window = TextLineScanner.tail(in: text, maximumLines: count)
            description = "last \(window.lines.count) of \(window.totalLineCount) lines"
        } else if let start = request.options.startLine {
            let count = min(max(request.options.maxLines ?? 500, 1), 5_000)
            window = TextLineScanner.window(
                in: text,
                startingAt: start,
                maximumLines: count
            )
            description = if let first = window.firstLine,
                             let last = window.lastLine {
                "lines \(first)-\(last) of \(window.totalLineCount)"
            } else {
                "no lines from line \(start) of \(window.totalLineCount)"
            }
        } else {
            window = TextLineScanner.tail(in: text, maximumLines: 500)
            description = "last \(window.lines.count) of \(window.totalLineCount) lines"
        }
        return .text(
            "Log: \(target.relativePath) (\(description))\n\n"
                + window.lines.joined(separator: "\n")
        )
    }

}
