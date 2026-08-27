import Foundation

enum LinkQuerySourceError: Error {
    case identifierTooLarge
}

enum VaultLocalLinkSyntax: String, Sendable {
    case wiki
    case markdown
}

struct ParsedVaultWikiLink: Equatable, Sendable {
    let target: String
    let resolutionTarget: String
    let fragment: String?
    let alias: String?
    let kind: VaultWikiLinkKind
    let occurrence: Int
    let syntax: VaultLocalLinkSyntax
}

/// Parses the supported local-link grammar, without filesystem access.
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
        guard let parsed = try wiki(body, kind: kind, occurrence: 1) else {
            throw LinkQueryError.invalidTarget
        }
        return parsed
    }

    static func forEach(in text: String, visit: (ParsedVaultWikiLink) throws -> Void) throws {
        var occurrence = 0
        try LocalMarkdownLinkScanner.forEach(in: text) { token in
            occurrence += 1
            switch token.syntax {
            case .wiki:
                if let parsed = try wiki(token.target, kind: token.kind, occurrence: occurrence, stored: true) {
                    try visit(parsed)
                }
            case .markdown:
                let fragmentIndex = token.target.firstIndex(of: "#")
                let beforeFragment = fragmentIndex.map { String(token.target[..<$0]) } ?? token.target
                let path = beforeFragment.split(
                    separator: "?", maxSplits: 1, omittingEmptySubsequences: false
                ).first.map(String.init) ?? ""
                if LocalMarkdownDestination.isExternal(path) { return }
                try validateIdentifier(token.target)
                if let alias = token.alias { try validateIdentifier(alias) }
                let fragment = fragmentIndex.map {
                    String(token.target[token.target.index(after: $0)...])
                }
                try visit(ParsedVaultWikiLink(
                    target: token.target, resolutionTarget: path, fragment: fragment,
                    alias: token.alias, kind: token.kind, occurrence: occurrence, syntax: .markdown
                ))
            }
        }
    }

    private static func wiki(
        _ body: String, kind: VaultWikiLinkKind, occurrence: Int, stored: Bool = false
    ) throws -> ParsedVaultWikiLink? {
        let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = parts.count == 2
            ? nonEmpty(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        guard !target.contains("\n"), !target.contains("\r"), !target.contains("\0") else { return nil }
        if stored, LocalMarkdownDestination.isExternalWiki(target) { return nil }
        try validateIdentifier(target)
        if let alias { try validateIdentifier(alias) }
        let separator = target.firstIndex(where: { $0 == "#" || $0 == "^" })
        let path = separator.map {
            String(target[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? target
        let fragment = separator.map { String(target[target.index(after: $0)...]) }
        return ParsedVaultWikiLink(
            target: target, resolutionTarget: path, fragment: fragment, alias: alias,
            kind: kind, occurrence: occurrence, syntax: .wiki
        )
    }

    private static func validateIdentifier(_ value: String) throws {
        guard value.utf8.count <= LinkQueryLimits.maximumTargetBytes else {
            throw LinkQuerySourceError.identifierTooLarge
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
