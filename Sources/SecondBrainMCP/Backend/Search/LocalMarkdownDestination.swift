import Foundation

/// URI classification and containment are pure operations; resolution uses the validated namespace only.
enum LocalMarkdownDestination {
    enum Location {
        case external
        case unresolved
        case vaultPath(String)
    }

    static func isExternal(_ path: String) -> Bool {
        let unescaped = unescapePunctuation(path)
        return hasNonlocalPrefix(unescaped)
            || unescaped.removingPercentEncoding.map(hasNonlocalPrefix) == true
    }

    static func isExternalWiki(_ path: String) -> Bool {
        guard let colon = path.firstIndex(of: ":") else { return false }
        let scheme = path[..<colon].lowercased()
        if ["http", "https", "mailto", "data", "file", "javascript"].contains(scheme) { return true }
        return hasNonlocalPrefix(path) && path[path.index(after: colon)...].hasPrefix("//")
    }

    static func location(of path: String, from source: String) -> Location {
        if isExternal(path) { return .external }
        guard let decoded = unescapePunctuation(path).removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.contains("\n"), !decoded.contains("\r") else { return .unresolved }
        if decoded.isEmpty { return .vaultPath(source) }
        var components = source.split(separator: "/").dropLast().map(String.init)
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return .unresolved }
                components.removeLast()
            default: components.append(String(component))
            }
        }
        guard components.first == "notes" || components.first == "references",
              components.count > 1 else { return .unresolved }
        let candidate = components.joined(separator: "/")
        guard !PathTraversalDetector.containsTraversal(in: candidate),
              !components.contains(where: { $0.hasPrefix(".") }) else { return .unresolved }
        return .vaultPath(candidate)
    }

    private static func unescapePunctuation(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 92, index + 1 < bytes.count,
               isPunctuation(bytes[index + 1]) {
                index += 1
            }
            result.append(bytes[index])
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func isPunctuation(_ byte: UInt8) -> Bool {
        (33...47).contains(byte) || (58...64).contains(byte)
            || (91...96).contains(byte) || (123...126).contains(byte)
    }

    private static func hasNonlocalPrefix(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        guard let colon = path.firstIndex(of: ":") else { return false }
        let scheme = path[..<colon].utf8
        guard let first = scheme.first, isLetter(first) else { return false }
        return scheme.dropFirst().allSatisfy {
            isLetter($0) || (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46
        }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}
