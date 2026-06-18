import Foundation

/// Resolves Obsidian-style links/embeds against the vault, and finds backlinks.
///
/// Sendable struct with **no persistent index** — each call walks the `notes/`
/// tree via `VaultEnumerator` and reads files on demand, the same philosophy as
/// `SearchEngine` (no startup indexing, just SSD reads when a query arrives).
///
/// ## Resolution semantics (mirrors Obsidian)
/// Obsidian resolves a wikilink/embed target by **basename across the whole
/// vault**, not relative to the linking note's folder — so `![[screenshot.png]]`
/// in `notes/apple/uikit/foo.md` resolves to `notes/apple/_attachments/screenshot.png`.
/// This type follows that: a bare name matches by basename vault-wide; a target
/// that contains a slash also matches by relative path; an extension-less target
/// implies `.md` (a note link). Ambiguous basenames return every candidate, best
/// (nearest to the linking note, then shortest path) first.
///
/// ## Safety
/// User input is only ever **string-matched against the enumerated candidate
/// list** — a link target or file reference is never used to open a path
/// directly. The only files opened are `VaultEnumerator` entries (clean,
/// sandboxed `notes/`-relative paths), so there is no path-traversal surface.
struct LinkResolver: Sendable {

    enum LinkResolverError: Error, CustomStringConvertible {
        case invalidPath(String)
        case notFound(String)

        var description: String {
            switch self {
            case .invalidPath(let reason): return "Invalid path: \(reason)"
            case .notFound(let ref): return "No vault file found for: \(ref)"
            }
        }
    }

    /// A wikilink/embed parsed out of note content (alias + subpath split off).
    struct ParsedLink: Sendable, Equatable {
        let target: String     // path or basename, with alias/subpath removed
        let subpath: String?   // "#heading" or "#^block" reference, if present
        let alias: String?     // "|display text", if present
        let isEmbed: Bool       // true for `![[...]]` / `![](...)`
        let raw: String        // the full matched text, e.g. "![[foo.png|alt]]"
    }

    /// The result of resolving one link target to vault file(s).
    struct Resolution: Sendable {
        let target: String     // the normalized target that was resolved
        let isEmbed: Bool
        let matches: [String]  // vault-relative paths, best match first; empty = unresolved
    }

    /// One note that references a given file.
    struct Backlink: Sendable {
        let notePath: String   // the referencing note (vault-relative)
        let raw: String        // the matched link text
        let isEmbed: Bool
    }

    private let vaultPath: String

    init(vaultPath: String) {
        self.vaultPath = vaultPath
    }

    // MARK: - Forward: resolve a link target to vault path(s)

    /// Resolve a single link target (bare, or written as `[[..]]`/`![[..]]`/
    /// `[..](..)`) to vault file path(s). `from` is the note the link appears in,
    /// used only to break basename ties by proximity.
    func resolve(link: String, from: String? = nil) throws -> Resolution {
        let parsed = Self.parseSingle(link)
        guard !parsed.target.isEmpty else {
            return Resolution(target: "", isEmbed: parsed.isEmbed, matches: [])
        }
        let candidates = try vaultFiles()
        let matches = Self.match(target: parsed.target, in: candidates, from: from)
        return Resolution(target: parsed.target, isEmbed: parsed.isEmbed, matches: matches)
    }

    // MARK: - Reverse: backlinks to a file

    /// Find every note that links to or embeds `file` (a vault-relative path or a
    /// bare basename). Each candidate link is resolved and kept only if it lands on
    /// the same file — so a basename shared by two files doesn't produce false hits.
    func backlinks(to file: String) throws -> [Backlink] {
        let candidates = try vaultFiles()
        let targetPath = try canonicalTarget(file, in: candidates)
        let targetBase = (targetPath as NSString).lastPathComponent
        let targetNoExt = (targetBase as NSString).deletingPathExtension

        var result: [Backlink] = []
        for entry in candidates where (entry.relativePath as NSString).pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOfFile: entry.fullPath, encoding: .utf8) else { continue }
            for link in Self.extractLinks(from: content) {
                // Cheap basename pre-filter before the full resolve.
                let last = (link.target as NSString).lastPathComponent
                let lastNoExt = (last as NSString).deletingPathExtension
                guard last.caseInsensitiveCompare(targetBase) == .orderedSame
                    || lastNoExt.caseInsensitiveCompare(targetNoExt) == .orderedSame else { continue }
                if Self.match(target: link.target, in: candidates, from: entry.relativePath).first == targetPath {
                    result.append(Backlink(notePath: entry.relativePath, raw: link.raw, isEmbed: link.isEmbed))
                }
            }
        }
        return result.sorted {
            $0.notePath != $1.notePath ? $0.notePath < $1.notePath : $0.raw < $1.raw
        }
    }

    // MARK: - Link extraction (structural)

    /// Extract every wikilink/embed and relative markdown link from note content,
    /// each split into target / subpath / alias and flagged as embed-or-not.
    /// External URLs (`http(s)://`, `mailto:`) are skipped.
    static func extractLinks(from content: String) -> [ParsedLink] {
        var result: [ParsedLink] = []

        // Wiki form: optional leading "!" (embed) then [[ ... ]].
        for m in content.matches(of: /(!?)\[\[([^\]]+)\]\]/) {
            let (target, subpath, alias) = parseWikiInner(String(m.2))
            guard !target.isEmpty else { continue }
            result.append(ParsedLink(target: target, subpath: subpath, alias: alias,
                                     isEmbed: !m.1.isEmpty, raw: String(m.0)))
        }

        // Markdown form: optional leading "!" then [text](target).
        for m in content.matches(of: /(!?)\[([^\]]*)\]\(([^)]+)\)/) {
            var target = String(m.3).trimmingCharacters(in: .whitespaces)
            // Drop an optional `(url "title")` title segment.
            if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
            let lower = target.lowercased()
            guard !lower.hasPrefix("http://"), !lower.hasPrefix("https://"), !lower.hasPrefix("mailto:") else { continue }
            var subpath: String? = nil
            if let hash = target.firstIndex(of: "#") {
                subpath = String(target[hash...])
                target = String(target[..<hash])
            }
            target = (target.removingPercentEncoding ?? target).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let alias = String(m.2).isEmpty ? nil : String(m.2)
            result.append(ParsedLink(target: target, subpath: subpath, alias: alias,
                                     isEmbed: !m.1.isEmpty, raw: String(m.0)))
        }

        return result
    }

    // MARK: - Private

    private func vaultFiles() throws -> [VaultEnumerator.Entry] {
        do {
            return try VaultEnumerator.files(
                vaultPath: vaultPath,
                directory: nil,
                defaultDir: "notes",
                recursive: true,
                include: { _ in true }
            )
        } catch {
            throw LinkResolverError.invalidPath("\(error)")
        }
    }

    /// Resolve a backlink target (full path or basename) to one canonical vault
    /// path. An exact relative-path match wins; otherwise the best basename match.
    private func canonicalTarget(_ file: String, in candidates: [VaultEnumerator.Entry]) throws -> String {
        let f = file.trimmingCharacters(in: .whitespaces)
        if let exact = candidates.first(where: { $0.relativePath == f }) { return exact.relativePath }
        let bare = f.hasPrefix("notes/") ? String(f.dropFirst("notes/".count)) : f
        guard let best = Self.match(target: bare, in: candidates, from: nil).first else {
            throw LinkResolverError.notFound(file)
        }
        return best
    }

    /// Candidate vault paths a target resolves to, best match first. See the
    /// type doc for the Obsidian-style semantics.
    static func match(target: String, in candidates: [VaultEnumerator.Entry], from: String?) -> [String] {
        let comps = target.split(separator: "/").map(String.init)
        guard let last = comps.last, !last.isEmpty else { return [] }
        let hasExt = !(last as NSString).pathExtension.isEmpty
        let wantSlash = comps.count > 1

        func basenameMatches(_ entry: VaultEnumerator.Entry) -> Bool {
            let base = (entry.relativePath as NSString).lastPathComponent
            if hasExt {
                return base.caseInsensitiveCompare(last) == .orderedSame
            }
            // Extension-less target → a note link; only `.md` files qualify.
            guard (entry.relativePath as NSString).pathExtension.lowercased() == "md" else { return false }
            let baseNoExt = (base as NSString).deletingPathExtension
            return baseNoExt.caseInsensitiveCompare(last) == .orderedSame
        }

        var hits = candidates.filter(basenameMatches)

        // If the target carried a path, prefer candidates whose path matches it.
        if wantSlash {
            let wantPath = hasExt ? target : target + ".md"
            let pathHits = hits.filter {
                $0.relativePath == "notes/" + wantPath || $0.relativePath.hasSuffix("/" + wantPath)
            }
            if !pathHits.isEmpty { hits = pathHits }
        }

        return hits.map(\.relativePath).sorted { a, b in
            let pa = proximity(a, to: from), pb = proximity(b, to: from)
            if pa != pb { return pa > pb }          // nearer to the linking note first
            if a.count != b.count { return a.count < b.count }   // then shortest path
            return a < b
        }
    }

    /// Count of shared leading path components between `path` and `from`.
    private static func proximity(_ path: String, to from: String?) -> Int {
        guard let from else { return 0 }
        var shared = 0
        for (x, y) in zip(path.split(separator: "/"), from.split(separator: "/")) {
            if x == y { shared += 1 } else { break }
        }
        return shared
    }

    /// Parse a single link string that may be bare or wrapped in `[[..]]` /
    /// `![[..]]` / `[..](..)`. Falls back to treating the raw text as a target.
    static func parseSingle(_ link: String) -> ParsedLink {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if let first = extractLinks(from: trimmed).first { return first }
        let (target, subpath, alias) = parseWikiInner(trimmed)   // strips |alias and #subpath
        return ParsedLink(target: target, subpath: subpath, alias: alias, isEmbed: false, raw: trimmed)
    }

    /// Split a wikilink interior `target#subpath|alias` into its parts. Alias is
    /// taken from the last `|`; subpath (with its leading `#`) from the first `#`.
    private static func parseWikiInner(_ inner: String) -> (target: String, subpath: String?, alias: String?) {
        var work = inner
        var alias: String? = nil
        if let pipe = work.firstIndex(of: "|") {
            alias = String(work[work.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            work = String(work[..<pipe])
        }
        var subpath: String? = nil
        if let hash = work.firstIndex(of: "#") {
            subpath = String(work[hash...])
            work = String(work[..<hash])
        }
        return (work.trimmingCharacters(in: .whitespaces), subpath, alias?.isEmpty == true ? nil : alias)
    }
}
