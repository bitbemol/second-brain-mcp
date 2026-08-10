import Foundation

/// Parsed Markdown data shared by file behavior and search atomization.
struct MarkdownMetadata: Sendable {
    let title: String?
    let created: String?
    let tags: Set<String>
    let body: String
}

/// Stateless Markdown metadata helpers.
enum MarkdownSupport {
    static func hasFrontmatter(_ text: String) -> Bool {
        metadata(from: text).hasFrontmatter
    }

    static func generateFrontmatter(
        title: String,
        tags: [String] = [],
        date: String? = nil
    ) -> String {
        let created = date ?? ISO8601DateFormatter().string(from: Date()).prefix(10).description
        var lines = ["---", "title: \(quotedYAMLScalar(title))", "created: \(created)"]
        let normalizedTags = tags.map(normalizeTag).filter { !$0.isEmpty }
        if !normalizedTags.isEmpty {
            let scalars = normalizedTags.map(quotedYAMLScalar).joined(separator: ", ")
            lines.append("tags: [\(scalars)]")
        }
        lines.append(contentsOf: ["---", "", ""])
        return lines.joined(separator: "\n")
    }

    /// Parses the small front-matter subset owned by this application.
    static func metadata(from text: String) -> (
        hasFrontmatter: Bool,
        value: MarkdownMetadata
    ) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return (false, MarkdownMetadata(title: nil, created: nil, tags: [], body: text))
        }

        var title: String?
        var created: String?
        var tags = Set<String>()
        var readingTags = false
        for rawLine in lines[1..<closing] {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if readingTags, trimmed.hasPrefix("-") {
                let tag = normalizeTag(scalar(String(trimmed.dropFirst())))
                if !tag.isEmpty { tags.insert(tag) }
                continue
            }
            readingTags = false
            if trimmed.lowercased().hasPrefix("title:") {
                title = scalar(String(trimmed.dropFirst("title:".count)))
            } else if trimmed.lowercased().hasPrefix("created:") {
                created = scalar(String(trimmed.dropFirst("created:".count)))
            } else if trimmed.lowercased().hasPrefix("tags:") {
                let raw = String(trimmed.dropFirst("tags:".count))
                    .trimmingCharacters(in: .whitespaces)
                if raw.isEmpty {
                    readingTags = true
                } else {
                    let content = raw.hasPrefix("[") && raw.hasSuffix("]")
                        ? String(raw.dropFirst().dropLast()) : raw
                    for item in content.split(separator: ",", omittingEmptySubsequences: false) {
                        let tag = normalizeTag(scalar(String(item)))
                        if !tag.isEmpty { tags.insert(tag) }
                    }
                }
            }
        }
        let bodyStart = lines.index(after: closing)
        let body = bodyStart < lines.endIndex
            ? lines[bodyStart...].joined(separator: "\n") : ""
        return (
            true,
            MarkdownMetadata(title: title, created: created, tags: tags, body: body)
        )
    }

    static func normalizeTag(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars
        if scalars.first?.value == 0x22, scalars.last?.value == 0x22,
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func quotedYAMLScalar(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    static func titleFromFilename(_ filename: String) -> String {
        (filename as NSString)
            .deletingPathExtension
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
