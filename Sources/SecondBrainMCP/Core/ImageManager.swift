import Foundation

/// Reads image files from the vault for viewing. Sendable struct — stateless,
/// no actor isolation needed; the platform work is delegated to an injected
/// `ImageEncoding` so this type stays pure policy and unit-testable.
///
/// ## Policy
/// - Pass an image **through untouched** when it's already within the model's
///   native limits (the common case for a screenshot). Re-encoding an image
///   does nothing for readability — the model reads PNG natively — so the only
///   reason to transform is size.
/// - Downscale + re-encode only when the source exceeds `maxLongEdge`.
/// - Reject decode bombs by **inspecting dimensions before decoding pixels**.
struct ImageManager: Sendable {

    struct Config: Sendable {
        /// Long-edge cap. Opus 4.8 vision handles ~2576px natively; larger is
        /// downscaled server-side anyway, so capping here loses nothing.
        let maxLongEdge: Int
        /// Hard file-size reject applied before the file is even opened.
        let maxFileBytes: Int
        /// Decode-bomb reject: refuse to decode beyond this many megapixels.
        let maxMegapixels: Double

        static let `default` = Config(
            maxLongEdge: 2576,
            maxFileBytes: 25 * 1024 * 1024,
            maxMegapixels: 50
        )
    }

    struct ImageResult: Sendable {
        let relativePath: String
        let pngData: Data
        let originalWidth: Int
        let originalHeight: Int
        let format: String
        let originalBytes: Int
        let wasResized: Bool
    }

    enum ImageError: Error, CustomStringConvertible {
        case invalidPath(String)
        case notFound(String)
        case fileTooLarge(bytes: Int, limit: Int)
        case tooManyPixels(megapixels: Double, limit: Double)

        var description: String {
            switch self {
            case .invalidPath(let reason):
                return "Invalid path: \(reason)"
            case .notFound(let path):
                return "Image not found: \(path)"
            case .fileTooLarge(let bytes, let limit):
                return "Image file is too large: \(bytes) bytes (limit \(limit))"
            case .tooManyPixels(let mp, let limit):
                return "Image has too many pixels: \(String(format: "%.1f", mp)) MP (limit \(String(format: "%.0f", limit)) MP)"
            }
        }
    }

    private let vaultPath: String
    private let encoder: ImageEncoding
    private let config: Config

    init(vaultPath: String, encoder: ImageEncoding, config: Config = .default) {
        self.vaultPath = vaultPath
        self.encoder = encoder
        self.config = config
    }

    /// Read a PNG from `notes/` or `references/`, returning bounded PNG bytes.
    func read(relativePath: String) throws -> ImageResult {
        guard relativePath.hasPrefix("notes/") || relativePath.hasPrefix("references/") else {
            throw ImageError.invalidPath("Path must be within notes/ or references/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: vaultPath,
            allowedExtensions: ["png"]
        )

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw ImageError.notFound(relativePath)
        }

        // 1. File-size guard, before opening anything.
        let attrs = try FileManager.default.attributesOfItem(atPath: resolved)
        let bytes = (attrs[.size] as? Int) ?? 0
        guard bytes <= config.maxFileBytes else {
            throw ImageError.fileTooLarge(bytes: bytes, limit: config.maxFileBytes)
        }

        let url = URL(fileURLWithPath: resolved)

        // 2. Inspect dimensions WITHOUT decoding pixels (decode-bomb guard).
        let info = try encoder.inspect(url: url)
        let megapixels = Double(info.pixelWidth) * Double(info.pixelHeight) / 1_000_000
        guard megapixels <= config.maxMegapixels else {
            throw ImageError.tooManyPixels(megapixels: megapixels, limit: config.maxMegapixels)
        }

        let longEdge = max(info.pixelWidth, info.pixelHeight)

        // 3. Pass through when within the cap; downscale+re-encode only when oversized.
        let pngData: Data
        let wasResized: Bool
        if longEdge <= config.maxLongEdge {
            pngData = try Data(contentsOf: url)
            wasResized = false
        } else {
            pngData = try encoder.encodeDownscaledPNG(url: url, maxLongEdge: config.maxLongEdge)
            wasResized = true
        }

        return ImageResult(
            relativePath: relativePath,
            pngData: pngData,
            originalWidth: info.pixelWidth,
            originalHeight: info.pixelHeight,
            format: info.format,
            originalBytes: bytes,
            wasResized: wasResized
        )
    }
}
