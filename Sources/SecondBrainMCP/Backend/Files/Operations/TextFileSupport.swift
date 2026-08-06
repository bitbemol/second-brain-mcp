import Foundation

/// Shared UTF-8 decoding and exact-replacement behavior for text formats.
enum TextFileSupport {
    /// Errors produced while decoding or patching text content.
    enum TextError: Error, CustomStringConvertible {
        /// Input bytes are not valid UTF-8.
        case invalidUTF8
        /// An operation requiring replacement or append content received none.
        case missingContent
        /// Patch mode received no replacement entries.
        case emptyPatch
        /// Patch mode exceeded the bounded replacement count.
        case tooManyPatches(Int)
        /// A replacement used an empty search value, which cannot identify a text range.
        case emptyPatchTarget(index: Int)
        /// A replacement's old text does not occur in the current document.
        case patchNotFound(index: Int)
        /// A replacement's old text is not unique in the current document.
        case ambiguousPatch(index: Int, occurrences: Int)

        /// Human-readable text decoding or replacement failure.
        var description: String {
            switch self {
            case .invalidUTF8: return "File is not valid UTF-8 text"
            case .missingContent: return "Missing required content"
            case .emptyPatch: return "No replacements provided"
            case .tooManyPatches(let count): return "Too many replacements: \(count). Maximum is 20."
            case .emptyPatchTarget(let index): return "Replacement \(index): old_text must not be empty"
            case .patchNotFound(let index):
                return "Replacement \(index): text not found; provide more context"
            case .ambiguousPatch(let index, let count):
                return "Replacement \(index): found \(count) occurrences; provide more context"
            }
        }
    }

    /// Decodes bytes as UTF-8 without lossy replacement.
    static func string(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TextError.invalidUTF8
        }
        return text
    }

    /// Strictly decodes UTF-8 while retaining a leading byte-order mark.
    ///
    /// `String(data:encoding:)` validates UTF-8 but consumes its leading BOM.
    /// JSON and CSV use this variant because their handlers promise byte-faithful
    /// reads and updates. The second decode cannot repair invalid input because
    /// the strict validation has already succeeded.
    static func stringPreservingByteOrderMark(from data: Data) throws -> String {
        guard String(data: data, encoding: .utf8) != nil else {
            throw TextError.invalidUTF8
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Appends text with one line boundary when neither side already supplies one.
    ///
    /// Empty values are concatenated unchanged, so appending to an empty file never
    /// invents a leading blank line and appending empty content remains a no-op.
    ///
    /// - Parameters:
    ///   - content: UTF-8 text supplied by the caller.
    ///   - original: Existing decoded file content.
    /// - Returns: The combined text with a line break inserted only when required.
    static func appending(_ content: String, to original: String) -> String {
        guard !original.isEmpty, !content.isEmpty else { return original + content }
        let originalEndsLine = original.unicodeScalars.last.map(CharacterSet.newlines.contains) ?? false
        let contentStartsLine = content.unicodeScalars.first.map(CharacterSet.newlines.contains) ?? false
        return original + (originalEndsLine || contentStartsLine ? "" : "\n") + content
    }

    /// Applies ordered, exact replacements to a UTF-8 document.
    ///
    /// Every `oldText` must occur exactly once at the point its replacement is
    /// evaluated. This prevents ambiguous edits and makes patch results predictable.
    ///
    /// - Parameters:
    ///   - replacements: Up to 20 ordered old/new text pairs.
    ///   - original: The current document content.
    /// - Returns: The document after all replacements are applied.
    /// - Throws: `TextError` when a replacement is absent, ambiguous, or invalid.
    static func apply(_ replacements: [TextReplacement], to original: String) throws -> String {
        guard !replacements.isEmpty else { throw TextError.emptyPatch }
        guard replacements.count <= 20 else { throw TextError.tooManyPatches(replacements.count) }

        var result = original
        for (offset, replacement) in replacements.enumerated() {
            guard !replacement.oldText.isEmpty else {
                throw TextError.emptyPatchTarget(index: offset + 1)
            }
            var occurrences = 0
            var searchStart = result.startIndex
            while let range = result.range(of: replacement.oldText, range: searchStart..<result.endIndex) {
                occurrences += 1
                searchStart = range.upperBound
            }
            guard occurrences > 0 else {
                throw TextError.patchNotFound(index: offset + 1)
            }
            guard occurrences == 1 else {
                throw TextError.ambiguousPatch(
                    index: offset + 1,
                    occurrences: occurrences
                )
            }
            guard let range = result.range(of: replacement.oldText) else {
                throw TextError.patchNotFound(index: offset + 1)
            }
            result.replaceSubrange(range, with: replacement.newText)
        }
        return result
    }
}
