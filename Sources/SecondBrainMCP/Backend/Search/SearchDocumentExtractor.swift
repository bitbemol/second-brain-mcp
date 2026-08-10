import Foundation

enum SearchAtomProviderError: Error, Sendable {
    case invalidUTF8(String)
    case invalidPDF(String)
}

/// Default atom provider for every globally registered textual format.
struct TextSearchAtomProvider: SearchAtomProvider {
    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> [SearchAtom] {
        guard let storedText = String(data: snapshot.data, encoding: .utf8) else {
            throw SearchAtomProviderError.invalidUTF8(target.relativePath)
        }
        if target.format == .markdown {
            let parsed = MarkdownSupport.metadata(from: storedText).value
            let title = parsed.title ?? ""
            let searchable = title.isEmpty ? parsed.body : title + "\n" + parsed.body
            return [SearchAtom(
                locator: VaultSearchResult(path: target.relativePath, format: target.format),
                text: searchable,
                metadata: SearchAtomMetadata(tags: parsed.tags, created: parsed.created)
            )]
        }
        return [SearchAtom(
            locator: VaultSearchResult(path: target.relativePath, format: target.format),
            text: storedText,
            metadata: nil
        )]
    }
}
