import Foundation

/// Listing and soft-deletion of binary attachments — any file under `notes/` that
/// isn't a first-class content type (note or canvas). Actor: `list` reuses
/// `VaultEnumerator` for the walk; `delete` soft-deletes to the vault `.trash/`.
/// The write is why this is an actor (serialized I/O, mirroring `CanvasManager`).
/// Closes the discovery + cleanup gap for images and other attachments.
actor AttachmentManager {

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
        case notFound(String)
        case notAnAttachment(String)

        var description: String {
            switch self {
            case .invalidPath(let reason): return "Invalid path: \(reason)"
            case .notFound(let path): return "Attachment not found: \(path)"
            case .notAnAttachment(let path): return "Not an attachment — use delete_note or delete_canvas: \(path)"
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

    /// Soft-delete an attachment by moving it to the vault `.trash/` (recoverable;
    /// the handler git-commits the deletion). Rejects notes and canvases — those
    /// have their own delete tools — and any path outside `notes/`. Mirrors
    /// `CanvasManager.delete`.
    func delete(relativePath: String) throws -> String {
        guard relativePath.hasPrefix("notes/") else {
            throw AttachmentError.invalidPath("Path must be within notes/: \(relativePath)")
        }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard !Self.contentExtensions.contains(ext) else {
            throw AttachmentError.notAnAttachment(relativePath)
        }
        let resolved: String
        do {
            resolved = try PathValidator.resolve(relativePath: relativePath, root: vaultPath, allowedExtensions: nil)
        } catch {
            throw AttachmentError.invalidPath("\(error)")
        }
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw AttachmentError.notFound(relativePath)
        }

        let trashDir = vaultPath + "/.trash"
        try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = (resolved as NSString).lastPathComponent
        let trashPath = trashDir + "/\(timestamp)_\(filename)"

        try FileManager.default.moveItem(atPath: resolved, toPath: trashPath)
        return "Deleted: \(relativePath) → .trash/\(timestamp)_\(filename)"
    }
}
