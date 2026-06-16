import Foundation

/// Read-only listing of binary attachments — any file under `notes/` that isn't a
/// first-class content type (note or canvas). Sendable struct, reuses
/// `VaultEnumerator` for the walk. Closes the discovery gap: images and other
/// attachments embedded in notes weren't enumerable through the server.
struct AttachmentManager: Sendable {

    private let vaultPath: String

    /// Extensions that have their own tools — NOT treated as attachments.
    private static let contentExtensions: Set<String> = ["md", "markdown", "canvas"]

    /// Extensions `read_image` can open — single source of truth lives on
    /// `ImageManager`, so the `readable` flag never drifts from what's supported.
    private static let readableExtensions = ImageManager.supportedExtensions

    struct AttachmentInfo: Sendable {
        let relativePath: String
        let ext: String          // lowercase; "" if the file has no extension
        let sizeBytes: Int
        let readable: Bool       // true if read_image can open it today
        let modifiedDate: Date
    }

    enum AttachmentError: Error, CustomStringConvertible {
        case invalidPath(String)

        var description: String {
            switch self {
            case .invalidPath(let reason): return "Invalid path: \(reason)"
            }
        }
    }

    init(vaultPath: String) {
        self.vaultPath = vaultPath
    }

    /// List binary attachments under `directory` (default `notes/`), newest-first.
    /// Honest enumeration: lists *all* non-note/non-canvas files and marks which
    /// ones `read_image` can currently open, rather than hiding unreadable formats.
    func list(directory: String? = nil, recursive: Bool = true) throws -> [AttachmentInfo] {
        let entries: [VaultEnumerator.Entry]
        do {
            entries = try VaultEnumerator.files(
                vaultPath: vaultPath,
                directory: directory,
                defaultDir: "notes",
                recursive: recursive,
                include: { !Self.contentExtensions.contains($0) }
            )
        } catch {
            throw AttachmentError.invalidPath("\(error)")
        }

        let fm = FileManager.default
        var results: [AttachmentInfo] = []
        for entry in entries {
            let ext = (entry.relativePath as NSString).pathExtension.lowercased()
            let size = ((try? fm.attributesOfItem(atPath: entry.fullPath))?[.size] as? Int) ?? 0
            results.append(AttachmentInfo(
                relativePath: entry.relativePath,
                ext: ext,
                sizeBytes: size,
                readable: Self.readableExtensions.contains(ext),
                modifiedDate: entry.modifiedDate
            ))
        }
        return results.sorted { $0.modifiedDate > $1.modifiedDate }
    }
}
