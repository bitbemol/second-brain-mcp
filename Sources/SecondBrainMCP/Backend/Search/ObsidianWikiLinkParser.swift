import Foundation

// MARK: - Obsidian wiki-link extraction

struct ParsedVaultWikiLink: Equatable, Sendable {
    let target: String
    let alias: String?
    let kind: VaultWikiLinkKind
    let occurrence: Int
}

enum ObsidianWikiLinkParser {
    static func parseRequest(_ value: String) throws -> ParsedVaultWikiLink {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LinkQueryError.emptyTarget }
        guard trimmed.utf8.count <= LinkQueryLimits.maximumTargetBytes else {
            throw LinkQueryError.targetTooLarge(limit: LinkQueryLimits.maximumTargetBytes)
        }
        let kind: VaultWikiLinkKind
        let body: String
        if trimmed.hasPrefix("![[") && trimmed.hasSuffix("]]") {
            kind = .embed
            body = String(trimmed.dropFirst(3).dropLast(2))
        } else if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
            kind = .link
            body = String(trimmed.dropFirst(2).dropLast(2))
        } else {
            kind = .link
            body = trimmed
        }
        guard let parsed = parseBody(body, kind: kind, occurrence: 1) else {
            throw LinkQueryError.invalidTarget
        }
        return parsed
    }

    static func extract(from text: String) -> [ParsedVaultWikiLink] {
        var result: [ParsedVaultWikiLink] = []
        var cursor = text.startIndex
        var occurrence = 0
        while cursor < text.endIndex,
              let opening = text.range(of: "[[", range: cursor..<text.endIndex) {
            let kind: VaultWikiLinkKind
            if opening.lowerBound > text.startIndex,
               text[text.index(before: opening.lowerBound)] == "!" {
                kind = .embed
            } else {
                kind = .link
            }
            let bodyStart = opening.upperBound
            guard let closing = text.range(of: "]]", range: bodyStart..<text.endIndex) else {
                break
            }
            occurrence += 1
            let body = String(text[bodyStart..<closing.lowerBound])
            if body.utf8.count <= LinkQueryLimits.maximumTargetBytes,
               let parsed = parseBody(body, kind: kind, occurrence: occurrence) {
                result.append(parsed)
            }
            cursor = closing.upperBound
        }
        return result
    }

    private static func parseBody(
        _ body: String,
        kind: VaultWikiLinkKind,
        occurrence: Int
    ) -> ParsedVaultWikiLink? {
        let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        var target = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = parts.count == 2
            ? nonEmpty(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        if let fragment = target.firstIndex(where: { $0 == "#" || $0 == "^" }) {
            target = String(target[..<fragment]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !target.contains("\n"), !target.contains("\r"), !target.contains("\0") else {
            return nil
        }
        return ParsedVaultWikiLink(
            target: target,
            alias: alias,
            kind: kind,
            occurrence: occurrence
        )
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
