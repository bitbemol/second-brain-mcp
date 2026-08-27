import Foundation
@testable import second_brain_mcp

/// Synthetic support storage stays outside the vault and is removed with its fixture.
func searchCaptureFixture(
    _ root: URL,
    observer: (@Sendable (ReadableFileTarget) -> Void)? = nil
) -> SearchCaptureStore {
    SearchCaptureStore(
        directory: root.appendingPathExtension("capture"), vaultRoot: root,
        captureObserver: observer
    )
}

func removeSearchFixture(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: root.appendingPathExtension("capture"))
    try? FileManager.default.removeItem(
        at: root.appendingPathExtension("capture.lock")
    )
}

/// Array fixtures adapt to the streaming production boundary only inside tests.
protocol ArraySearchAtomSource: VaultSearchAtomSource {
    func atoms(in location: VaultArea) async throws -> [SearchAtom]
}

extension ArraySearchAtomSource {
    /// Synthetic atom fixtures may supply any concrete format.
    var searchableFormats: [FileFormat] { FileFormat.allCases }

    @discardableResult
    func scan(
        _ request: VaultSearchRequest,
        consume: @escaping @Sendable (SearchDocument) async throws -> Void
    ) async throws -> Set<FileFormat> {
        let ordered = try await atoms(in: request.location).sorted(by: SearchFingerprint.precedes)
        var start = 0
        while start < ordered.count {
            try Task.checkCancellation()
            let first = ordered[start].locator
            var end = start + 1
            while end < ordered.count,
                  ordered[end].locator.path == first.path,
                  ordered[end].locator.format == first.format {
                end += 1
            }
            let metadataOnly = !request.tags.isEmpty || request.createdFrom != nil
                || request.createdThrough != nil
            let inDirectory = request.directory.map {
                first.path.hasPrefix(request.location.rawValue + "/" + $0 + "/")
            } ?? true
            if !inDirectory || (!request.formats.isEmpty && !request.formats.contains(first.format))
                || (metadataOnly && first.format != .markdown) {
                start = end
                continue
            }
            try await consume(SearchDocument(
                path: first.path, format: first.format, revision: nil,
                atoms: Array(ordered[start..<end]), failure: nil
            ))
            start = end
        }
        var formats = Set(request.formats.isEmpty ? searchableFormats : request.formats)
        if !request.tags.isEmpty || request.createdFrom != nil || request.createdThrough != nil {
            formats.formIntersection([.markdown])
        }
        return formats
    }
}


actor SearchDocumentCollector {
    private(set) var documents: [SearchDocument] = []
    func append(_ document: SearchDocument) { documents.append(document) }

    static func atoms(from source: any VaultSearchAtomSource, in location: VaultArea) async throws -> [SearchAtom] {
        let collector = SearchDocumentCollector()
        try await source.scan(VaultSearchRequest(location: location)) {
            await collector.append($0)
        }
        return await collector.documents.flatMap(\.atoms)
    }
}
