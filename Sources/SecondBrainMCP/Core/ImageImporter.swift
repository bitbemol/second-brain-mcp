import Foundation

/// Imports an image **from an arbitrary path on disk into the vault**, re-encoding
/// it to a clean PNG. Actor because the write (and optional source removal) must be
/// serialized, mirroring `VaultManager` / `CanvasManager`.
///
/// This is the only tool that reads a path **outside** the vault sandbox. The
/// destination is still fully `PathValidator`-gated (under `notes/`), and the
/// **image decode is the security gate on the source**: a renamed script, an
/// archive, or any non-image won't decode via `ImageEncoding.inspect`, so it is
/// rejected before anything is written. Re-encoding to PNG then guarantees that
/// only pixels land in the vault — EXIF, trailing bytes, and any appended/polyglot
/// payload are stripped. (Re-encode is a deliberate choice over a verbatim copy;
/// the codebase's "reject, don't sanitize" rule is about hostile *paths*, whereas
/// decoding-and-re-encoding pixels is the same normalization `read_image` already
/// performs.)
actor ImageImporter {

    enum ImageImporterError: Error, CustomStringConvertible {
        case invalidDestination(String)
        case sourceNotFound(String)
        case sourceNotAFile(String)
        case sourceInsideVault(String)
        case sourceTooLarge(bytes: Int, limit: Int)
        case notAnImage(String)
        case unsupportedFormat(String)
        case tooManyPixels(megapixels: Double, limit: Double)
        case destinationExists(String)
        case writeFailed(String, underlying: String)

        var description: String {
            switch self {
            case .invalidDestination(let reason): return "Invalid destination: \(reason)"
            case .sourceNotFound(let path): return "Source file not found: \(path)"
            case .sourceNotAFile(let path): return "Source is not a regular file: \(path)"
            case .sourceInsideVault(let path): return "Source is inside the vault — add_image imports external files only: \(path)"
            case .sourceTooLarge(let bytes, let limit): return "Source image is too large: \(bytes) bytes (limit \(limit))"
            case .notAnImage(let path): return "Source is not a readable image: \(path)"
            case .unsupportedFormat(let fmt): return "Unsupported image format: \(fmt)"
            case .tooManyPixels(let mp, let limit): return "Image has too many pixels: \(String(format: "%.1f", mp)) MP (limit \(String(format: "%.0f", limit)) MP)"
            case .destinationExists(let path): return "Destination already exists: \(path)"
            case .writeFailed(let path, let underlying): return "Failed to write \(path): \(underlying)"
            }
        }
    }

    struct ImportResult: Sendable {
        let destination: String    // final vault-relative path (always .png)
        let sourceFormat: String   // detected source format, e.g. "jpeg"
        let width: Int
        let height: Int
        let bytesWritten: Int
        let sourceDeleted: Bool
        let note: String?          // non-fatal note, e.g. an animated source flattened to one frame
    }

    private let vaultPath: String
    private let encoder: ImageEncoding
    private let config: ImageManager.Config   // reuse read_image's caps

    init(vaultPath: String, encoder: ImageEncoding, config: ImageManager.Config = .default) {
        self.vaultPath = vaultPath
        self.encoder = encoder
        self.config = config
    }

    /// Validate `source` as a real image and import it into the vault at
    /// `destination` (normalized to a `.png`), re-encoded to a clean PNG. When
    /// `deleteSource` is true the source file is removed afterward (best-effort —
    /// the import has already succeeded, so a failed removal is reported, not fatal).
    func add(source: String, destination: String, deleteSource: Bool) throws -> ImportResult {
        // 1. Destination (vault side) — must be under notes/, normalized to .png,
        //    path-gated, and must not already exist (no clobber).
        let finalRel = Self.normalizedDestination(destination)
        guard finalRel.hasPrefix("notes/") else {
            throw ImageImporterError.invalidDestination("Destination must be within notes/: \(destination)")
        }
        let resolvedDest: String
        do {
            resolvedDest = try PathValidator.resolve(relativePath: finalRel, root: vaultPath, allowedExtensions: ["png"])
        } catch {
            throw ImageImporterError.invalidDestination("\(error)")
        }
        guard !FileManager.default.fileExists(atPath: resolvedDest) else {
            throw ImageImporterError.destinationExists(finalRel)
        }

        // 2. Source (external). Canonicalize FIRST — resolve symlinks so every check
        //    below applies to the *real* target, not a symlink that could point at a
        //    file past the size cap, at a device/FIFO, or back inside the vault.
        let src = URL(fileURLWithPath: source.trimmingCharacters(in: .whitespaces)).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: src) else {
            throw ImageImporterError.sourceNotFound(source)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: src)
        // Must be a regular file — rejects directories, FIFOs, sockets, and devices.
        // (A FIFO source would otherwise block the decoder and stall the actor.)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw ImageImporterError.sourceNotAFile(source)
        }
        // Size cap on the *resolved* target (a symlink stats tiny, hiding a huge target).
        let bytes = (attrs[.size] as? Int) ?? 0
        guard bytes <= config.maxFileBytes else {
            throw ImageImporterError.sourceTooLarge(bytes: bytes, limit: config.maxFileBytes)
        }
        // add_image is for EXTERNAL files. Refuse a source inside the vault: otherwise
        // delete_source would hard-delete vault content, bypassing soft-delete (Rule 5).
        guard !Self.isInsideVault(src, vaultPath: vaultPath) else {
            throw ImageImporterError.sourceInsideVault(source)
        }

        // 3. Prove it's a real, supported image WITHOUT decoding pixels, then bound
        //    megapixels (decode-bomb guard) — this is the gate on the external path.
        let srcURL = URL(fileURLWithPath: src)
        let info: ImageInspection
        do {
            info = try encoder.inspect(url: srcURL)
        } catch {
            throw ImageImporterError.notAnImage(source)
        }
        guard ImageManager.supportedExtensions.contains(info.format.lowercased()) else {
            throw ImageImporterError.unsupportedFormat(info.format)
        }
        let megapixels = Double(info.pixelWidth) * Double(info.pixelHeight) / 1_000_000
        guard megapixels <= config.maxMegapixels else {
            throw ImageImporterError.tooManyPixels(megapixels: megapixels, limit: config.maxMegapixels)
        }

        // 4. Re-encode to a clean PNG at full resolution (no downscale — we're
        //    storing the artifact, not sizing it for the model). Decoding here is
        //    what strips any non-pixel data.
        let longEdge = max(info.pixelWidth, info.pixelHeight)
        let png: Data
        do {
            png = try encoder.encodeFramePNG(url: srcURL, frameIndex: 0, maxLongEdge: longEdge)
        } catch {
            throw ImageImporterError.notAnImage(source)
        }

        // 5. Write into the vault.
        let parent = (resolvedDest as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: resolvedDest), options: .atomic)
        } catch {
            throw ImageImporterError.writeFailed(finalRel, underlying: error.localizedDescription)
        }

        // 6. Optionally remove the source (best-effort; import already succeeded).
        //    Soft-delete: move to the system Trash (recoverable) rather than unlink,
        //    consistent with the vault's "soft deletes only" rule for user content.
        var sourceDeleted = false
        if deleteSource {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: src), resultingItemURL: nil)
                sourceDeleted = true
            } catch {
                sourceDeleted = false
            }
        }

        let note = info.frameCount > 1 ? "source was an animated image; imported its first frame only" : nil
        return ImportResult(
            destination: finalRel,
            sourceFormat: info.format,
            width: info.pixelWidth,
            height: info.pixelHeight,
            bytesWritten: png.count,
            sourceDeleted: sourceDeleted,
            note: note
        )
    }

    /// Whether `path` (already symlink-resolved) sits within the vault root. Both
    /// sides are canonicalized and compared with a trailing-slash prefix so
    /// `/vault-evil` doesn't count as inside `/vault`.
    static func isInsideVault(_ path: String, vaultPath: String) -> Bool {
        let root = URL(fileURLWithPath: vaultPath).resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(prefix)
    }

    /// We always store PNG, so force a `.png` extension on the destination
    /// (replacing any other) and trim surrounding whitespace.
    static func normalizedDestination(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        let noExt = (trimmed as NSString).deletingPathExtension
        return noExt.isEmpty ? trimmed : noExt + ".png"
    }
}
