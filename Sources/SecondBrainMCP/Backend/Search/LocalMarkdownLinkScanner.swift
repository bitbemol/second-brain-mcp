import Foundation

/// A streaming scanner for wiki and inline Markdown links, not reference-style Markdown.
enum LocalMarkdownLinkScanner {
    struct Token {
        let target: String
        let alias: String?
        let kind: VaultWikiLinkKind
        let syntax: VaultLocalLinkSyntax
    }

    static func forEach(in text: String, visit: (Token) throws -> Void) throws {
        try Task.checkCancellation()
        var scanner = Scanner(bytes: Array(text.utf8))
        try scanner.run(visit: visit)
        try Task.checkCancellation()
    }

    private struct Scanner {
        let bytes: [UInt8]
        var cursor = 0
        var atLineStart = true
        var fence: (marker: UInt8, count: Int)?
        var paragraphEnd = 0
        var lastBacktickRun: [Int: Int] = [:]
        var cancellationCountdown = 0

        mutating func run(visit: (Token) throws -> Void) throws {
            while cursor < bytes.count {
                try checkpoint()
                if atLineStart {
                    if let marker = try fenceMarker(at: cursor) {
                        if let current = fence {
                            let end = try lineEnd(from: marker.end)
                            if current.marker == marker.marker, marker.count >= current.count,
                               onlyWhitespace(from: marker.end, to: end) {
                                fence = nil
                            }
                        } else {
                            fence = (marker.marker, marker.count)
                        }
                        try skipLine()
                        continue
                    }
                    if fence != nil { try skipLine(); continue }
                    atLineStart = false
                }
                switch bytes[cursor] {
                case 10, 13:
                    atLineStart = true
                    cursor += 1
                case 92:
                    if cursor + 1 < bytes.count, bytes[cursor + 1] == 10 || bytes[cursor + 1] == 13 {
                        atLineStart = true
                    }
                    cursor = min(cursor + 2, bytes.count)
                case 96:
                    try skipCodeSpan()
                case 33 where cursor + 1 < bytes.count && bytes[cursor + 1] == 91:
                    cursor += 1
                    try scanLink(kind: .embed, visit: visit)
                case 91:
                    try scanLink(kind: .link, visit: visit)
                default:
                    cursor += 1
                }
            }
        }

        mutating func scanLink(kind: VaultWikiLinkKind, visit: (Token) throws -> Void) throws {
            let opening = cursor
            if opening + 1 < bytes.count, bytes[opening + 1] == 91 {
                var end = opening + 2
                while end + 1 < bytes.count, bytes[end] != 10, bytes[end] != 13 {
                    try checkpoint()
                    if bytes[end] == 92 { end += 2; continue }
                    if bytes[end] == 93, bytes[end + 1] == 93 {
                        let body = String(decoding: bytes[(opening + 2)..<end], as: UTF8.self)
                        cursor = end + 2
                        try Task.checkCancellation()
                        try visit(Token(target: body, alias: nil, kind: kind, syntax: .wiki))
                        return
                    }
                    end += 1
                }
                cursor = max(opening + 2, min(end, bytes.count))
                return
            }

            var labelEnd = opening + 1
            var labelDepth = 1
            var nestedWiki: Int?
            while labelEnd < bytes.count, bytes[labelEnd] != 10, bytes[labelEnd] != 13 {
                try checkpoint()
                if bytes[labelEnd] == 92 { labelEnd += 2; continue }
                if bytes[labelEnd] == 91 {
                    if nestedWiki == nil, labelEnd + 1 < bytes.count, bytes[labelEnd + 1] == 91 {
                        nestedWiki = labelEnd
                    }
                    labelDepth += 1
                }
                if bytes[labelEnd] == 93 {
                    labelDepth -= 1
                    if labelDepth == 0 { break }
                }
                labelEnd += 1
            }
            guard labelEnd + 1 < bytes.count, bytes[labelEnd] == 93,
                  bytes[labelEnd + 1] == 40 else {
                if let nestedWiki {
                    cursor = nestedWiki
                } else if labelEnd < bytes.count, bytes[labelEnd] == 10 || bytes[labelEnd] == 13 {
                    cursor = labelEnd
                } else {
                    cursor = min(labelEnd + 1, bytes.count)
                }
                return
            }
            guard let range = try scanDestination(at: labelEnd + 2) else { return }
            let target = String(decoding: bytes[range], as: UTF8.self)
            let label = String(decoding: bytes[(opening + 1)..<labelEnd], as: UTF8.self)
            try Task.checkCancellation()
            try visit(Token(
                target: target, alias: label.isEmpty ? nil : label,
                kind: kind, syntax: .markdown
            ))
        }

        /// Extracts only the destination, excluding angle delimiters and an optional title.
        mutating func scanDestination(at start: Int) throws -> Range<Int>? {
            var index = start
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 {
                try checkpoint()
                index += 1
            }
            let range: Range<Int>
            if index < bytes.count, bytes[index] == 60 {
                index += 1
                let lower = index
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13, bytes[index] != 62 {
                    try checkpoint()
                    index += bytes[index] == 92 ? 2 : 1
                }
                guard index < bytes.count, bytes[index] == 62 else {
                    cursor = min(index, bytes.count)
                    return nil
                }
                range = lower..<index
                index += 1
            } else {
                let lower = index
                var depth = 0
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 {
                    try checkpoint()
                    if bytes[index] == 92 { index += 2; continue }
                    if depth == 0, bytes[index] == 32 || bytes[index] == 9 || bytes[index] == 41 { break }
                    if bytes[index] == 40 { depth += 1 }
                    if bytes[index] == 41 { depth -= 1 }
                    index += 1
                }
                guard depth == 0, index <= bytes.count else {
                    cursor = min(index, bytes.count)
                    return nil
                }
                range = lower..<index
            }
            let beforeWhitespace = index
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 {
                try checkpoint()
                index += 1
            }
            if index > beforeWhitespace, index < bytes.count,
               bytes[index] == 34 || bytes[index] == 39 || bytes[index] == 40 {
                let closing: UInt8 = bytes[index] == 40 ? 41 : bytes[index]
                index += 1
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13, bytes[index] != closing {
                    try checkpoint()
                    index += bytes[index] == 92 ? 2 : 1
                }
                guard index < bytes.count, bytes[index] == closing else {
                    cursor = min(index, bytes.count)
                    return nil
                }
                index += 1
                while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 {
                    try checkpoint()
                    index += 1
                }
            }
            guard index < bytes.count, bytes[index] == 41 else {
                cursor = min(index, bytes.count)
                return nil
            }
            cursor = index + 1
            return range
        }

        /// One paragraph look-ahead prevents repeated scans for unmatched backtick runs.
        /// Distinct run lengths occupy at most O(sqrt(source bytes)) dictionary entries.
        mutating func prepareParagraph() throws {
            lastBacktickRun.removeAll(keepingCapacity: true)
            var index = cursor
            var lineStart = cursor
            while index < bytes.count {
                try checkpoint()
                if index == lineStart, index > cursor {
                    let end = try lineEnd(from: index)
                    let hasFence = try fenceMarker(at: index) != nil
                    if onlyWhitespace(from: index, to: end) || hasFence {
                        break
                    }
                }
                if bytes[index] == 96 {
                    let start = index
                    while index < bytes.count, bytes[index] == 96 {
                        try checkpoint()
                        index += 1
                    }
                    lastBacktickRun[index - start] = start
                } else {
                    if bytes[index] == 10 || bytes[index] == 13 { lineStart = index + 1 }
                    index += 1
                }
            }
            paragraphEnd = max(cursor + 1, index)
        }

        mutating func skipCodeSpan() throws {
            if cursor >= paragraphEnd { try prepareParagraph() }
            let start = cursor
            while cursor < bytes.count, bytes[cursor] == 96 {
                try checkpoint()
                cursor += 1
            }
            let count = cursor - start
            guard let last = lastBacktickRun[count], last > start else { return }
            while cursor < paragraphEnd {
                try checkpoint()
                if bytes[cursor] != 96 { cursor += 1; continue }
                let runStart = cursor
                while cursor < bytes.count, bytes[cursor] == 96 {
                    try checkpoint()
                    cursor += 1
                }
                if cursor - runStart == count { return }
            }
        }

        mutating func fenceMarker(at start: Int) throws -> (marker: UInt8, count: Int, end: Int)? {
            var index = start
            while index < bytes.count, index - start < 4, bytes[index] == 32 { index += 1 }
            guard index - start <= 3, index < bytes.count,
                  bytes[index] == 96 || bytes[index] == 126 else { return nil }
            let marker = bytes[index]
            let runStart = index
            while index < bytes.count, bytes[index] == marker {
                try checkpoint()
                index += 1
            }
            guard index - runStart >= 3 else { return nil }
            return (marker, index - runStart, index)
        }

        mutating func skipLine() throws {
            cursor = try lineEnd(from: cursor)
            if cursor < bytes.count { cursor += 1 }
            atLineStart = true
        }

        mutating func lineEnd(from start: Int) throws -> Int {
            var index = start
            while index < bytes.count, bytes[index] != 10, bytes[index] != 13 {
                try checkpoint()
                index += 1
            }
            return index
        }

        func onlyWhitespace(from start: Int, to end: Int) -> Bool {
            bytes[start..<end].allSatisfy { $0 == 32 || $0 == 9 }
        }

        mutating func checkpoint() throws {
            if cancellationCountdown == 0 {
                try Task.checkCancellation()
                cancellationCountdown = 4096
            }
            cancellationCountdown -= 1
        }
    }
}
