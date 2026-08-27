import CryptoKit
import Foundation

/// Rebuildable PDF text generations. Callers hold the shared PDF admission permit
/// across lookup/publication so independent runtimes cannot race the cache quota.
struct PDFSearchCache: Sendable {
    private struct Page: Codable {
        let byteCount: Int
        let digest: String
    }

    private struct Manifest: Codable {
        let version: Int
        let revision: String
        let pageCount: Int
        let byteCount: Int
        let pages: [Page]
    }

    /// Conservative cache-only budgets; reaching either disables publication,
    /// never successful source extraction. No eviction or mutation authority.
    private static let maximumBytes = 64 * 1_024 * 1_024
    private static let maximumEntries = 1_024
    private static let maximumPageBytes = 2 * 1_024 * 1_024
    private static let maximumManifestBytes = 256 * 1_024
    // Version 3 separates derived text from the pre-migration OCR implementation.
    private static let version = 3

    let root: URL

    func pages(
        path: String, revision: String, beforePage: () throws -> Void = {}
    ) throws -> [String] {
        try Task.checkCancellation()
        let directory = generation(path: path, revision: revision)
        let data = try read(
            directory.appendingPathComponent("manifest.json"),
            maximumBytes: Self.maximumManifestBytes
        )
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == Self.version,
              manifest.revision == revision,
              manifest.pageCount >= 0,
              manifest.pageCount <= Self.maximumEntries - 3,
              manifest.pageCount == manifest.pages.count,
              (0...Self.maximumBytes).contains(manifest.byteCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var total = 0
        for page in manifest.pages {
            try Task.checkCancellation()
            guard (0...Self.maximumPageBytes).contains(page.byteCount),
                  page.byteCount <= Self.maximumBytes - total,
                  page.digest.utf8.count == 64 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            total += page.byteCount
        }
        guard total == manifest.byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var result: [String] = []
        result.reserveCapacity(manifest.pageCount)
        for (index, page) in manifest.pages.enumerated() {
            try Task.checkCancellation()
            try beforePage()
            let data = try read(pageURL(index, in: directory), maximumBytes: page.byteCount)
            guard data.count == page.byteCount,
                  Self.digest(data) == page.digest,
                  let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(text)
        }
        try Task.checkCancellation()
        return result
    }

    func store(_ texts: [String], path: String, revision: String) throws {
        try Task.checkCancellation()
        guard texts.count <= Self.maximumEntries - 3 else { return }
        var pages: [Page] = []
        pages.reserveCapacity(texts.count)
        var totalBytes = 0
        for text in texts {
            try Task.checkCancellation()
            let bytes = text.utf8.count
            guard bytes <= Self.maximumPageBytes,
                  bytes <= Self.maximumBytes - totalBytes else { return }
            totalBytes += bytes
            pages.append(Page(byteCount: bytes, digest: Self.digest(Data(text.utf8))))
        }
        let manifest = Manifest(
            version: Self.version,
            revision: revision,
            pageCount: pages.count,
            byteCount: totalBytes,
            pages: pages
        )
        let manifestData = try JSONEncoder().encode(manifest)
        guard manifestData.count <= Self.maximumManifestBytes,
              manifestData.count <= Self.maximumBytes - totalBytes else { return }
        totalBytes += manifestData.count

        let manager = FileManager.default
        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let final = generation(path: path, revision: revision)
        // A published generation is immutable, including when corrupt. Failed
        // lookup falls back to source; publication never overwrites active readers.
        guard !manager.fileExists(atPath: final.path) else { return }
        guard try canPublish(bytes: totalBytes, entries: texts.count + 3) else { return }

        let parent = final.deletingLastPathComponent()
        try manager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = parent.appendingPathComponent(".pending-\(UUID().uuidString)")
        try manager.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: temporary) }
        for (index, text) in texts.enumerated() {
            try Task.checkCancellation()
            try write(Data(text.utf8), to: pageURL(index, in: temporary))
        }
        try write(manifestData, to: temporary.appendingPathComponent("manifest.json"))
        try Task.checkCancellation()
        // Same-parent no-clobber rename publishes the complete generation at once.
        try manager.moveItem(at: temporary, to: final)
    }

    private func canPublish(bytes: Int, entries: Int) throws -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            return false
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            if let enumerationError { throw enumerationError }
            throw CocoaError(.fileReadUnknown)
        }
        var observedEntries = 0
        var observedBytes = 0
        while let file = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard observedEntries < Self.maximumEntries - entries else { return false }
            observedEntries += 1
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { return false }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0,
                      size <= Self.maximumBytes - bytes - observedBytes else {
                    return false
                }
                observedBytes += size
            } else if values.isDirectory != true {
                return false
            }
        }
        if let enumerationError { throw enumerationError }
        return true
    }

    private func generation(path: String, revision: String) -> URL {
        root.appendingPathComponent("pdf-pages-v\(Self.version)", isDirectory: true)
            .appendingPathComponent(
                "\(Self.digest(Data(path.utf8)))-\(revision)",
                isDirectory: true
            )
    }

    private func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try BoundedFileReader.read(
            from: url,
            maximumBytes: maximumBytes,
            path: "PDF derived cache"
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func pageURL(_ index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "page-%05d.txt", index + 1))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
