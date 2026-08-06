import Foundation

/// Stateless Markdown helpers shared by Markdown creation and PDF titles.
enum MarkdownSupport {
    /// Detects a complete YAML front-matter block at the document start.
    ///
    /// A lone Markdown thematic break (`---`) is not front matter; a matching
    /// closing delimiter must appear on a later line.
    static func hasFrontmatter(_ text: String) -> Bool {
        var hasOpeningDelimiter = false
        var hasClosingDelimiter = false
        TextLineScanner.forEachLine(in: text) { line, lineNumber in
            guard !hasClosingDelimiter else { return }
            let value = String(line).trimmingCharacters(in: .whitespaces)
            if lineNumber == 1 {
                hasOpeningDelimiter = value == "---"
            } else if hasOpeningDelimiter, value == "---" {
                hasClosingDelimiter = true
            }
        }
        return hasOpeningDelimiter && hasClosingDelimiter
    }

    /// Builds YAML front matter for a newly created Markdown note.
    ///
    /// - Parameters:
    ///   - title: Human-readable note title.
    ///   - tags: Tags normalized to lowercase and embedded as a YAML list.
    ///   - date: Optional `YYYY-MM-DD` creation date; defaults to today.
    /// - Returns: Front matter ending with a blank line, ready to prefix content.
    static func generateFrontmatter(
        title: String,
        tags: [String] = [],
        date: String? = nil
    ) -> String {
        let created = date ?? ISO8601DateFormatter().string(from: Date()).prefix(10).description
        var lines = ["---", "title: \(quotedYAMLScalar(title))", "created: \(created)"]
        let normalizedTags = tags
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !normalizedTags.isEmpty {
            let scalars = normalizedTags.map(quotedYAMLScalar).joined(separator: ", ")
            lines.append("tags: [\(scalars)]")
        }
        lines.append(contentsOf: ["---", "", ""])
        return lines.joined(separator: "\n")
    }

    /// Encodes an arbitrary value as one YAML double-quoted scalar line.
    ///
    /// YAML recognizes JSON-style Unicode escapes inside double quotes. Escaping
    /// control and line-separator scalars prevents caller text from terminating
    /// the generated field or introducing additional front-matter records.
    private static func quotedYAMLScalar(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x00...0x1F, 0x7F, 0x85, 0x2028, 0x2029:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// Derives a readable title by removing the extension and replacing separators.
    static func titleFromFilename(_ filename: String) -> String {
        (filename as NSString)
            .deletingPathExtension
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
