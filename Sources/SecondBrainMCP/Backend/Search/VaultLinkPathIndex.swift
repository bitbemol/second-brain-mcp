import Foundation

struct VaultLinkPathIndex {
    private let exact: [String: VaultLinkFile]
    private let byFoldedPath: [String: [VaultLinkFile]]
    private let byName: [String: [VaultLinkFile]]
    private let byMarkdownStem: [String: [VaultLinkFile]]

    init(files: [VaultLinkFile]) throws {
        var exact: [String: VaultLinkFile] = [:]
        var byFoldedPath: [String: [VaultLinkFile]] = [:]
        var byName: [String: [VaultLinkFile]] = [:]
        var byMarkdownStem: [String: [VaultLinkFile]] = [:]
        for file in files {
            try Task.checkCancellation()
            exact[file.path] = file
            byFoldedPath[Self.key(file.path), default: []].append(file)
            let name = (file.path as NSString).lastPathComponent
            byName[Self.key(name), default: []].append(file)
            if file.format == .markdown {
                let stem = (name as NSString).deletingPathExtension
                byMarkdownStem[Self.key(stem), default: []].append(file)
            }
        }
        self.exact = exact
        self.byFoldedPath = byFoldedPath.mapValues { $0.sorted { $0.path < $1.path } }
        self.byName = byName.mapValues { $0.sorted { $0.path < $1.path } }
        self.byMarkdownStem = byMarkdownStem.mapValues {
            $0.sorted { $0.path < $1.path }
        }
    }

    func validatedContextPath(_ path: String) throws -> String {
        guard let file = uniquePathCandidate(path),
              file.format == .markdown,
              file.path.hasPrefix("notes/") else {
            throw LinkQueryError.invalidFromPath
        }
        return file.path
    }

    func validatedSourcePath(_ path: String) throws -> String {
        guard let file = uniquePathCandidate(path),
              file.format == .markdown,
              file.path.hasPrefix("notes/") else {
            throw LinkQueryError.invalidTarget
        }
        return file.path
    }

    func resolve(
        _ target: String,
        fromPath: String?
    ) throws -> [VaultLinkFile] {
        guard !target.hasPrefix("/"),
              !target.contains("\\"),
              !PathTraversalDetector.containsTraversal(in: target) else {
            throw LinkQueryError.invalidTarget
        }
        if target.isEmpty {
            guard let fromPath, let file = uniquePathCandidate(fromPath) else {
                return []
            }
            return [file]
        }

        let hasExtension = !(target as NSString).pathExtension.isEmpty
        if target.contains("/") {
            var paths: [String] = []
            let concrete = hasExtension ? target : target + ".md"
            if concrete.hasPrefix("notes/") || concrete.hasPrefix("references/") {
                paths.append(concrete)
            }
            if let fromPath {
                let directory = (fromPath as NSString).deletingLastPathComponent
                paths.append((directory as NSString).appendingPathComponent(concrete))
            }
            paths.append("notes/" + concrete)
            if hasExtension { paths.append("references/" + concrete) }
            var seen: Set<String> = []
            return paths.flatMap { path in
                pathCandidates(path).filter { seen.insert($0.path).inserted }
            }
        }

        let candidates: [VaultLinkFile]
        if hasExtension {
            candidates = byName[Self.key(target)] ?? []
        } else {
            candidates = byMarkdownStem[Self.key(target)] ?? []
        }
        return candidates.sorted {
            let lhsRank = proximity(of: $0.path, to: fromPath)
            let rhsRank = proximity(of: $1.path, to: fromPath)
            return lhsRank == rhsRank ? $0.path < $1.path : lhsRank < rhsRank
        }
    }

    /// Stored Markdown hrefs never reach PathValidator or a filesystem open.
    func markdownCandidates(_ path: String, fromPath: String) -> [VaultLinkFile]? {
        switch LocalMarkdownDestination.location(of: path, from: fromPath) {
        case .external: return nil
        case .unresolved: return []
        case .vaultPath(let candidate): return pathCandidates(candidate)
        }
    }

    func closestCandidates(
        _ target: String,
        fromPath: String
    ) throws -> [VaultLinkFile] {
        let candidates = try resolve(target, fromPath: fromPath)
        guard let closest = candidates.first else { return [] }
        let closestRank = proximity(of: closest.path, to: fromPath)
        return candidates.prefix {
            proximity(of: $0.path, to: fromPath) == closestRank
        }.map { $0 }
    }

    /// Exact canonical spelling identifies one file; folded spelling can identify several.
    private func pathCandidates(_ path: String) -> [VaultLinkFile] {
        if let file = exact[path] { return [file] }
        return byFoldedPath[Self.key(path)] ?? []
    }

    private func uniquePathCandidate(_ path: String) -> VaultLinkFile? {
        let candidates = pathCandidates(path)
        return candidates.count == 1 ? candidates.first : nil
    }

    private func proximity(of candidate: String, to source: String?) -> Int {
        guard let source else { return 0 }
        let sourceDirectory = (source as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        let candidateDirectory = (candidate as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        var common = 0
        while common < min(sourceDirectory.count, candidateDirectory.count),
              Self.key(sourceDirectory[common]) == Self.key(candidateDirectory[common]) {
            common += 1
        }
        return sourceDirectory.count + candidateDirectory.count - 2 * common
    }

    private static func key(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
