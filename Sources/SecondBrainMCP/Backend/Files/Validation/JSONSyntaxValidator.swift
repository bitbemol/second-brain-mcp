import Foundation

/// Strict, non-materializing RFC 8259 JSON syntax validation.
///
/// Foundation's JSON decoders accept trailing commas and materialize complete
/// object graphs. This parser validates UTF-8 bytes directly, accepts arbitrary
/// precision number spellings, and caps nesting before recursion can exhaust the
/// process stack. A leading UTF-8 byte-order mark is tolerated for interoperability
/// but remains part of the caller's preserved representation.
enum JSONSyntaxValidator {
    /// JSON syntax or resource-shape validation failed.
    enum ValidationError: Error, Sendable {
        /// Bytes do not form exactly one strict JSON value.
        case invalidSyntax
        /// Container nesting exceeds the parser's defensive ceiling.
        case excessiveNesting
        /// The representation contains more values than the caller permits.
        case excessiveValueCount
    }

    private static let maximumNestingDepth = 512

    /// Validates one complete UTF-8 JSON representation without decoding values.
    ///
    /// - Parameters:
    ///   - data: Candidate UTF-8 JSON bytes.
    ///   - rejectingDuplicateObjectKeys: Whether an object may repeat a decoded
    ///     member name. HAR sanitization enables this because materializing a
    ///     duplicate-key object would otherwise silently discard one value.
    @discardableResult
    static func validate(
        _ data: Data,
        rejectingDuplicateObjectKeys: Bool = false,
        maximumValueCount: Int? = nil
    ) throws -> Int {
        try Task.checkCancellation()
        guard String(data: data, encoding: .utf8) != nil else {
            throw ValidationError.invalidSyntax
        }
        var parser = Parser(
            bytes: Array(data),
            rejectsDuplicateObjectKeys: rejectingDuplicateObjectKeys,
            maximumValueCount: maximumValueCount
        )
        return try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        let rejectsDuplicateObjectKeys: Bool
        let maximumValueCount: Int?
        var index = 0
        var valueCount = 0

        mutating func parseDocument() throws -> Int {
            consumeByteOrderMark()
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard isAtEnd else { throw ValidationError.invalidSyntax }
            return valueCount
        }

        private mutating func parseValue(depth: Int) throws {
            valueCount += 1
            if let maximumValueCount, valueCount > maximumValueCount {
                throw ValidationError.excessiveValueCount
            }
            if valueCount.isMultiple(of: 1_024) {
                try Task.checkCancellation()
            }
            guard let byte = current else {
                throw ValidationError.invalidSyntax
            }
            switch byte {
            case CharacterByte.objectStart:
                try parseObject(depth: depth)
            case CharacterByte.arrayStart:
                try parseArray(depth: depth)
            case CharacterByte.quote:
                _ = try parseString(decoding: false)
            case CharacterByte.minus,
                 CharacterByte.zero...CharacterByte.nine:
                try parseNumber()
            case CharacterByte.t:
                try parseLiteral([CharacterByte.t, 0x72, 0x75, 0x65])
            case CharacterByte.f:
                try parseLiteral([CharacterByte.f, 0x61, 0x6c, 0x73, 0x65])
            case CharacterByte.n:
                try parseLiteral([CharacterByte.n, 0x75, 0x6c, 0x6c])
            default:
                throw ValidationError.invalidSyntax
            }
        }

        private mutating func parseObject(depth: Int) throws {
            try requireContainerDepth(depth)
            advance()
            skipWhitespace()
            if consume(CharacterByte.objectEnd) { return }
            var memberNames = Set<String>()

            while true {
                guard current == CharacterByte.quote else {
                    throw ValidationError.invalidSyntax
                }
                let memberName = try parseString(
                    decoding: rejectsDuplicateObjectKeys
                )
                if rejectsDuplicateObjectKeys {
                    guard let memberName,
                          memberNames.insert(memberName).inserted else {
                        throw ValidationError.invalidSyntax
                    }
                }
                skipWhitespace()
                guard consume(CharacterByte.colon) else {
                    throw ValidationError.invalidSyntax
                }
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(CharacterByte.objectEnd) { return }
                guard consume(CharacterByte.comma) else {
                    throw ValidationError.invalidSyntax
                }
                skipWhitespace()
                // The loop's required string rejects a trailing comma.
            }
        }

        private mutating func parseArray(depth: Int) throws {
            try requireContainerDepth(depth)
            advance()
            skipWhitespace()
            if consume(CharacterByte.arrayEnd) { return }

            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(CharacterByte.arrayEnd) { return }
                guard consume(CharacterByte.comma) else {
                    throw ValidationError.invalidSyntax
                }
                skipWhitespace()
                // The next required value rejects a trailing comma.
            }
        }

        private mutating func parseString(
            decoding: Bool
        ) throws -> String? {
            let start = index
            guard consume(CharacterByte.quote) else {
                throw ValidationError.invalidSyntax
            }
            while let byte = current {
                advance()
                switch byte {
                case CharacterByte.quote:
                    guard decoding else { return nil }
                    let representation = Data(bytes[start..<index])
                    guard let decoded = try? JSONDecoder().decode(
                        String.self,
                        from: representation
                    ) else {
                        throw ValidationError.invalidSyntax
                    }
                    return decoded
                case CharacterByte.escape:
                    try parseEscape()
                case 0x00...0x1f:
                    throw ValidationError.invalidSyntax
                default:
                    continue
                }
            }
            throw ValidationError.invalidSyntax
        }

        private mutating func parseEscape() throws {
            guard let byte = current else {
                throw ValidationError.invalidSyntax
            }
            advance()
            switch byte {
            case CharacterByte.quote, CharacterByte.escape, 0x2f,
                 0x62, 0x66, 0x6e, 0x72, 0x74:
                return
            case 0x75:
                for _ in 0..<4 {
                    guard let digit = current, Self.isHexadecimal(digit) else {
                        throw ValidationError.invalidSyntax
                    }
                    advance()
                }
            default:
                throw ValidationError.invalidSyntax
            }
        }

        private mutating func parseNumber() throws {
            _ = consume(CharacterByte.minus)
            guard let first = current else {
                throw ValidationError.invalidSyntax
            }
            if first == CharacterByte.zero {
                advance()
                if let next = current, Self.isDigit(next) {
                    throw ValidationError.invalidSyntax
                }
            } else {
                guard Self.isNonzeroDigit(first) else {
                    throw ValidationError.invalidSyntax
                }
                consumeDigits()
            }

            if consume(CharacterByte.period) {
                guard let digit = current, Self.isDigit(digit) else {
                    throw ValidationError.invalidSyntax
                }
                consumeDigits()
            }

            if current == CharacterByte.e || current == CharacterByte.uppercaseE {
                advance()
                if current == CharacterByte.plus || current == CharacterByte.minus {
                    advance()
                }
                guard let digit = current, Self.isDigit(digit) else {
                    throw ValidationError.invalidSyntax
                }
                consumeDigits()
            }
        }

        private mutating func parseLiteral(_ literal: [UInt8]) throws {
            for expected in literal {
                guard consume(expected) else {
                    throw ValidationError.invalidSyntax
                }
            }
        }

        private func requireContainerDepth(_ depth: Int) throws {
            guard depth < JSONSyntaxValidator.maximumNestingDepth else {
                throw ValidationError.excessiveNesting
            }
        }

        private mutating func consumeDigits() {
            while let byte = current, Self.isDigit(byte) { advance() }
        }

        private mutating func consumeByteOrderMark() {
            guard bytes.count >= 3,
                  bytes[0] == 0xef,
                  bytes[1] == 0xbb,
                  bytes[2] == 0xbf else { return }
            index = 3
        }

        private mutating func skipWhitespace() {
            while let byte = current,
                  byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
                advance()
            }
        }

        private var current: UInt8? {
            isAtEnd ? nil : bytes[index]
        }

        private var isAtEnd: Bool { index == bytes.count }

        @discardableResult
        private mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            advance()
            return true
        }

        private mutating func advance() {
            index += 1
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            (CharacterByte.zero...CharacterByte.nine).contains(byte)
        }

        private static func isNonzeroDigit(_ byte: UInt8) -> Bool {
            (0x31...CharacterByte.nine).contains(byte)
        }

        private static func isHexadecimal(_ byte: UInt8) -> Bool {
            isDigit(byte)
                || (0x41...0x46).contains(byte)
                || (0x61...0x66).contains(byte)
        }
    }

    /// Named ASCII bytes used by the strict parser state machine.
    private enum CharacterByte {
        static let quote: UInt8 = 0x22
        static let plus: UInt8 = 0x2b
        static let comma: UInt8 = 0x2c
        static let minus: UInt8 = 0x2d
        static let period: UInt8 = 0x2e
        static let zero: UInt8 = 0x30
        static let nine: UInt8 = 0x39
        static let colon: UInt8 = 0x3a
        static let uppercaseE: UInt8 = 0x45
        static let arrayStart: UInt8 = 0x5b
        static let escape: UInt8 = 0x5c
        static let arrayEnd: UInt8 = 0x5d
        static let f: UInt8 = 0x66
        static let e: UInt8 = 0x65
        static let n: UInt8 = 0x6e
        static let t: UInt8 = 0x74
        static let objectStart: UInt8 = 0x7b
        static let objectEnd: UInt8 = 0x7d
    }
}
