import Foundation

/// Produces bounded PDF strings whose JSON wire growth is predictable.
enum PDFDisplayText {
    struct Bounded: Sendable {
        let value: String
        let truncated: Bool
    }

    /// Replaces non-layout control characters that JSON would expand heavily.
    static func sanitized(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value {
            if character == "\n" || character == "\r" || character == "\t" {
                result.append(character)
                continue
            }
            result.append(character.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            } ? character : " ")
        }
        return result
    }

    /// Sanitizes and retains only complete characters inside a UTF-8 ceiling.
    static func bounded(_ value: String, maximumBytes: Int) -> String {
        bounded(
            value,
            maximumCharacters: .max,
            maximumBytes: maximumBytes
        ).value
    }

    /// Single-pass bounded metadata projection with explicit truncation.
    static func bounded(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> Bounded {
        guard maximumCharacters > 0, maximumBytes > 0 else {
            return Bounded(value: "", truncated: !value.isEmpty)
        }
        var result = ""
        // The ceiling may be several MiB for page text. Reserving that full
        // amount for every short page multiplies retained capacity across an
        // indexed book, so begin small and let genuinely large values grow.
        result.reserveCapacity(min(maximumBytes, 4 * 1_024))
        var retainedBytes = 0
        var retainedCharacters = 0
        for character in value {
            let safeCharacter: Character
            if character == "\n" || character == "\r" || character == "\t" {
                safeCharacter = character
            } else {
                safeCharacter = character.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                } ? character : " "
            }
            let bytes = String(safeCharacter).utf8.count
            guard retainedCharacters < maximumCharacters,
                  retainedBytes + bytes <= maximumBytes else {
                return Bounded(value: result, truncated: true)
            }
            result.append(safeCharacter)
            retainedBytes += bytes
            retainedCharacters += 1
        }
        return Bounded(value: result, truncated: false)
    }
}
