import AppKit
import CryptoKit
import Foundation
import PDFKit
import Vision

/// Produces one searchable atom per physical PDF page and caches derived text.
struct PDFSearchAtomProvider: SearchAtomProvider {
    private struct Manifest: Codable {
        let revision: String
        let pageCount: Int
    }

    private let cacheRoot: URL
    private let admission: PDFReadAdmission

    init(cacheRoot: URL, admission: PDFReadAdmission) {
        self.cacheRoot = cacheRoot
        self.admission = admission
    }

    func atoms(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) async throws -> [SearchAtom] {
        let texts: [String] = try await admission.withPermit {
            try self.pageTexts(for: target, snapshot: snapshot)
        }
        return texts.enumerated().map { index, text in
            SearchAtom(
                locator: VaultSearchResult(
                    path: target.relativePath,
                    format: .pdf,
                    page: index + 1
                ),
                text: text,
                metadata: nil
            )
        }
    }

    private func pageTexts(
        for target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> [String] {
        let directory = cacheDirectory(for: target.relativePath)
        if let cached = try? cachedPages(
            in: directory,
            revision: snapshot.revision.rawValue
        ) {
            return cached
        }

        guard let document = PDFDocument(data: snapshot.data) else {
            throw SearchAtomProviderError.invalidPDF(target.relativePath)
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = try autoreleasepool {
                guard let page = document.page(at: index) else { return "" }
                let embedded = page.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !embedded.isEmpty { return Self.bounded(embedded) }
                return try Self.recognizedText(on: page)
            }
            pages.append(text)
        }
        try store(
            pages,
            revision: snapshot.revision.rawValue,
            in: directory
        )
        return pages
    }

    private func cachedPages(in directory: URL, revision: String) throws -> [String] {
        let manifestData = try Data(
            contentsOf: directory.appendingPathComponent("manifest.json")
        )
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.revision == revision, manifest.pageCount >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard manifest.pageCount > 0 else { return [] }
        return try (1...manifest.pageCount).map { page in
            let data = try Data(contentsOf: pageURL(page, in: directory))
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return text
        }
    }

    private func store(_ pages: [String], revision: String, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for (index, text) in pages.enumerated() {
            try Data(text.utf8).write(
                to: pageURL(index + 1, in: directory),
                options: .atomic
            )
        }
        let manifest = Manifest(revision: revision, pageCount: pages.count)
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func cacheDirectory(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheRoot
            .appendingPathComponent("pdf-pages", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private func pageURL(_ page: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "page-%05d.txt", page))
    }

    private static func recognizedText(on page: PDFPage) throws -> String {
        let image = page.thumbnail(of: NSSize(width: 1_800, height: 1_800), for: .mediaBox)
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let text = request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n") ?? ""
        return bounded(text)
    }

    private static func bounded(_ value: String) -> String {
        let maximumBytes = 2 * 1_024 * 1_024
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(maximumBytes)
        for scalar in value.unicodeScalars {
            let next = String(scalar)
            guard result.utf8.count + next.utf8.count <= maximumBytes else { break }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
