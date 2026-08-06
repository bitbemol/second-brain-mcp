/// Structural facts derived from one validated CSV document.
struct CSVInspection: Equatable, Sendable {
    /// Logical records, including a header when present.
    let rowCount: Int
    /// Fields in every logical record, or zero for an empty document.
    let columnCount: Int
}

/// Streaming RFC-style CSV validator that does not retain individual fields.
///
/// The parser accepts comma delimiters, quoted fields, doubled quote escapes,
/// embedded CR/LF line breaks inside quotes, and CRLF, LF, or CR record endings.
/// Every logical row must contain the same number of fields.
enum CSVDocumentInspector {
    /// A CSV payload violates quoting or table-shape invariants.
    enum ValidationError: Error, CustomStringConvertible, Sendable {
        /// An unquoted field contains a quote.
        case quoteInUnquotedField(row: Int, column: Int)
        /// A quoted field is followed by data rather than a delimiter or newline.
        case characterAfterClosingQuote(row: Int, column: Int)
        /// The final quoted field never closes.
        case unterminatedQuotedField(row: Int, column: Int)
        /// One record has a different number of fields from the first record.
        case inconsistentColumns(row: Int, expected: Int, actual: Int)

        var description: String {
            switch self {
            case .quoteInUnquotedField(let row, let column):
                return "Invalid CSV quote in row \(row), column \(column)"
            case .characterAfterClosingQuote(let row, let column):
                return "Invalid character after closing CSV quote in row \(row), column \(column)"
            case .unterminatedQuotedField(let row, let column):
                return "Unterminated CSV quote in row \(row), column \(column)"
            case .inconsistentColumns(let row, let expected, let actual):
                return "CSV row \(row) has \(actual) columns; expected \(expected)"
            }
        }
    }

    private enum State: Equatable {
        case fieldStart
        case unquoted
        case quoted
        case afterClosingQuote
    }

    /// Validates one UTF-8 CSV string and reports its table dimensions.
    static func inspect(_ text: String) throws -> CSVInspection {
        guard !text.isEmpty else {
            return CSVInspection(rowCount: 0, columnCount: 0)
        }

        var state = State.fieldStart
        var rowCount = 0
        var fieldsInRow = 0
        var expectedColumns: Int?
        var endedWithRecordDelimiter = false
        var skipLineFeedAfterCarriageReturn = false

        func currentRow() -> Int { rowCount + 1 }
        func currentColumn() -> Int { fieldsInRow + 1 }

        func finishField() {
            fieldsInRow += 1
            state = .fieldStart
        }

        func finishRow() throws {
            rowCount += 1
            if let expectedColumns, expectedColumns != fieldsInRow {
                throw ValidationError.inconsistentColumns(
                    row: rowCount,
                    expected: expectedColumns,
                    actual: fieldsInRow
                )
            }
            if expectedColumns == nil {
                expectedColumns = fieldsInRow
            }
            fieldsInRow = 0
            state = .fieldStart
        }

        func finishRecordDelimiter(carriageReturn: Bool) throws {
            finishField()
            try finishRow()
            endedWithRecordDelimiter = true
            skipLineFeedAfterCarriageReturn = carriageReturn
        }

        var isFirstScalar = true
        for scalar in text.unicodeScalars {
            if isFirstScalar {
                isFirstScalar = false
                if scalar == "\u{feff}" { continue }
            }
            if skipLineFeedAfterCarriageReturn {
                skipLineFeedAfterCarriageReturn = false
                if scalar == "\n" { continue }
            }

            switch state {
            case .fieldStart:
                switch scalar {
                case "\"":
                    state = .quoted
                    endedWithRecordDelimiter = false
                case ",":
                    finishField()
                    endedWithRecordDelimiter = false
                case "\r":
                    try finishRecordDelimiter(carriageReturn: true)
                case "\n":
                    try finishRecordDelimiter(carriageReturn: false)
                default:
                    state = .unquoted
                    endedWithRecordDelimiter = false
                }

            case .unquoted:
                switch scalar {
                case "\"":
                    throw ValidationError.quoteInUnquotedField(
                        row: currentRow(),
                        column: currentColumn()
                    )
                case ",":
                    finishField()
                    endedWithRecordDelimiter = false
                case "\r":
                    try finishRecordDelimiter(carriageReturn: true)
                case "\n":
                    try finishRecordDelimiter(carriageReturn: false)
                default:
                    endedWithRecordDelimiter = false
                }

            case .quoted:
                if scalar == "\"" {
                    state = .afterClosingQuote
                }
                endedWithRecordDelimiter = false

            case .afterClosingQuote:
                switch scalar {
                case "\"":
                    state = .quoted
                    endedWithRecordDelimiter = false
                case ",":
                    finishField()
                    endedWithRecordDelimiter = false
                case "\r":
                    try finishRecordDelimiter(carriageReturn: true)
                case "\n":
                    try finishRecordDelimiter(carriageReturn: false)
                default:
                    throw ValidationError.characterAfterClosingQuote(
                        row: currentRow(),
                        column: currentColumn()
                    )
                }
            }
        }

        if state == .quoted {
            throw ValidationError.unterminatedQuotedField(
                row: currentRow(),
                column: currentColumn()
            )
        }
        if !endedWithRecordDelimiter {
            finishField()
            try finishRow()
        }

        return CSVInspection(
            rowCount: rowCount,
            columnCount: expectedColumns ?? 0
        )
    }
}
