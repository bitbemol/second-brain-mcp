import Foundation

/// Shared, sandboxed file enumeration for the `list_*` tools. Centralizes the
/// directory walk, extension filtering, clean vault-relative path construction,
/// and placeholder/dotfile skipping — so `list_notes`, `list_canvas`, and
/// `list_attachments` all behave consistently.
///
/// Fixes two long-standing listing bugs in one place:
/// - the `notes//foo` double-slash (callers passing a trailing-slash directory)
/// - `.gitkeep` / `.gitkeep.md` placeholders (and other dotfiles / hidden dirs)
///   leaking into listings.
struct VaultEnumerator {

    struct Entry: Sendable {
        let relativePath: String   // clean vault-relative path, e.g. "notes/a/b.md"
        let fullPath: String
        let modifiedDate: Date
    }

    enum EnumeratorError: Error, CustomStringConvertible {
        case outsideRoot(String, root: String)

        var description: String {
            switch self {
            case .outsideRoot(let dir, let root):
                return "Directory must be within \(root)/: \(dir)"
            }
        }
    }

    /// Enumerate files under `directory` (vault-relative; defaults to `defaultDir`),
    /// keeping only files whose lowercase extension passes `include`.
    /// Skips directories, dotfiles, `.gitkeep` placeholders, and anything inside a
    /// hidden directory. Returns clean vault-relative paths (never doubled slashes).
    static func files(
        vaultPath: String,
        directory: String?,
        defaultDir: String,
        recursive: Bool,
        include: (_ ext: String) -> Bool
    ) throws -> [Entry] {
        // Normalize the requested directory: strip trailing slashes so the path
        // join below can't produce "notes//...".
        var relDir = directory ?? defaultDir
        while relDir.hasSuffix("/") { relDir.removeLast() }

        guard relDir == defaultDir || relDir.hasPrefix(defaultDir + "/") else {
            throw EnumeratorError.outsideRoot(directory ?? relDir, root: defaultDir)
        }

        let baseDir = try PathValidator.resolve(relativePath: relDir, root: vaultPath)

        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDir) else { return [] }

        let parts: [String]
        if recursive {
            guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }
            parts = enumerator.compactMap { $0 as? String }
        } else {
            parts = (try? fm.contentsOfDirectory(atPath: baseDir)) ?? []
        }

        var entries: [Entry] = []
        for part in parts {
            // Skip dotfiles, `.gitkeep.md` placeholders, and anything under a hidden
            // directory — any path component beginning with "." is excluded.
            if part.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }

            let ext = (part as NSString).pathExtension.lowercased()
            guard include(ext) else { continue }

            let fullPath = baseDir + "/" + part
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

            let modDate = (try? fm.attributesOfItem(atPath: fullPath))?[.modificationDate] as? Date ?? Date()
            entries.append(Entry(
                relativePath: relDir + "/" + part,   // clean single-slash join
                fullPath: fullPath,
                modifiedDate: modDate
            ))
        }
        return entries
    }
}
