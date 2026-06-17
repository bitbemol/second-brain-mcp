import Foundation

/// Reads image files from the vault for viewing. Sendable struct — stateless,
/// no actor isolation needed; the platform work is delegated to an injected
/// `ImageEncoding` so this type stays pure policy and unit-testable.
///
/// ## Policy
/// - **Still images** within the model's native resolution **pass through
///   untouched** (the common case for a screenshot) — re-encoding does nothing
///   for readability, the only reason to transform is size. Formats the API
///   accepts natively (png/jpeg/gif/webp) pass through with their own mime type;
///   others (heic/tiff/bmp) are re-encoded to PNG so the API accepts them.
/// - Oversized stills are downscaled + re-encoded to PNG.
/// - **Animated GIFs** are decomposed into a bundle of evenly-sampled PNG frames,
///   each tagged with its wall-clock offset from the GIF's frame delays, so the
///   model reads them as a *timed* sequence (it can't perceive GIF motion — or
///   pacing — from a single image).
/// - Decode bombs are rejected by **inspecting dimensions before decoding pixels**.
struct ImageManager: Sendable {

    /// Extensions `read_image` can open. Single source of truth — `AttachmentManager`
    /// reads this to set its `readable` flag, so the two never drift. SVG is excluded
    /// (XML → XXE risk; it's vector text a note can hold instead).
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"
    ]

    /// Formats the Claude API accepts as-is. Others must be re-encoded to PNG.
    private static let apiNativeMime: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp"
    ]

    struct Config: Sendable {
        /// Long-edge cap for a still image. Opus 4.8 vision handles ~2576px
        /// natively; larger is downscaled server-side anyway.
        let maxLongEdge: Int
        /// Hard file-size reject applied before the file is even opened.
        let maxFileBytes: Int
        /// Decode-bomb reject: refuse to decode beyond this many megapixels.
        let maxMegapixels: Double
        /// Max frames sampled from an animated GIF.
        let gifMaxFrames: Int
        /// Long-edge cap per sampled GIF frame (smaller than a single still, since
        /// there are several in one response).
        let gifFrameMaxLongEdge: Int

        static let `default` = Config(
            maxLongEdge: 2576,
            maxFileBytes: 25 * 1024 * 1024,
            maxMegapixels: 50,
            gifMaxFrames: 8,
            gifFrameMaxLongEdge: 1280
        )
    }

    struct Frame: Sendable {
        let data: Data
        let mimeType: String
        let sourceIndex: Int   // frame index in the source (0 for a still image)
        /// Wall-clock offset of this frame from the animation's start, in seconds
        /// (the sum of all frame delays before it). `nil` for stills or when the
        /// GIF carries no timing — gives the model pacing, not just frame order.
        let timeOffsetSeconds: Double?
    }

    struct ImageResult: Sendable {
        let relativePath: String
        let format: String
        let originalWidth: Int
        let originalHeight: Int
        let originalBytes: Int
        let totalFrames: Int       // source frame count (1 for a still image)
        let frames: [Frame]        // 1 for a still, the sampled set for an animated GIF
        let passedThrough: Bool    // still image returned byte-for-byte (no re-encode)
        /// Full animation duration in seconds (sum of all source frame delays).
        /// `nil` for stills or when the GIF carries no timing.
        let totalDurationSeconds: Double?
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

    /// Read an image from `notes/` or `references/`.
    func read(relativePath: String) throws -> ImageResult {
        guard relativePath.hasPrefix("notes/") || relativePath.hasPrefix("references/") else {
            throw ImageError.invalidPath("Path must be within notes/ or references/: \(relativePath)")
        }

        let resolved = try PathValidator.resolve(
            relativePath: relativePath,
            root: vaultPath,
            allowedExtensions: Self.supportedExtensions
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
        let ext = (resolved as NSString).pathExtension.lowercased()

        // 2. Inspect dimensions WITHOUT decoding pixels (decode-bomb guard).
        let info = try encoder.inspect(url: url)
        let megapixels = Double(info.pixelWidth) * Double(info.pixelHeight) / 1_000_000
        guard megapixels <= config.maxMegapixels else {
            throw ImageError.tooManyPixels(megapixels: megapixels, limit: config.maxMegapixels)
        }

        // 3a. Animated GIF → sampled PNG frame bundle.
        if ext == "gif", info.frameCount > 1 {
            let indices = Self.sampleIndices(total: info.frameCount, max: config.gifMaxFrames)
            let delays = info.frameDelays
            let frames = try indices.map { index in
                Frame(
                    data: try encoder.encodeFramePNG(url: url, frameIndex: index, maxLongEdge: config.gifFrameMaxLongEdge),
                    mimeType: "image/png",
                    sourceIndex: index,
                    timeOffsetSeconds: delays.map { Self.cumulativeTime(delays: $0, before: index) }
                )
            }
            let duration = delays.map { $0.reduce(0, +) }
            return result(relativePath, info, bytes, totalFrames: info.frameCount, frames: frames,
                          passedThrough: false, totalDuration: duration)
        }

        // 3b. Still image: pass through when API-native and within cap; otherwise
        //     re-encode to PNG (oversized, or a format the API won't accept as-is).
        let longEdge = max(info.pixelWidth, info.pixelHeight)
        if let nativeMime = Self.apiNativeMime[ext], longEdge <= config.maxLongEdge {
            let data = try Data(contentsOf: url)
            let frame = Frame(data: data, mimeType: nativeMime, sourceIndex: 0, timeOffsetSeconds: nil)
            return result(relativePath, info, bytes, totalFrames: 1, frames: [frame], passedThrough: true, totalDuration: nil)
        } else {
            let png = try encoder.encodeFramePNG(url: url, frameIndex: 0, maxLongEdge: config.maxLongEdge)
            let frame = Frame(data: png, mimeType: "image/png", sourceIndex: 0, timeOffsetSeconds: nil)
            return result(relativePath, info, bytes, totalFrames: 1, frames: [frame], passedThrough: false, totalDuration: nil)
        }
    }

    private func result(
        _ relativePath: String, _ info: ImageInspection, _ bytes: Int,
        totalFrames: Int, frames: [Frame], passedThrough: Bool, totalDuration: Double?
    ) -> ImageResult {
        ImageResult(
            relativePath: relativePath,
            format: info.format,
            originalWidth: info.pixelWidth,
            originalHeight: info.pixelHeight,
            originalBytes: bytes,
            totalFrames: totalFrames,
            frames: frames,
            passedThrough: passedThrough,
            totalDurationSeconds: totalDuration
        )
    }

    /// Wall-clock start time (seconds) of source frame `index`: the sum of every
    /// frame delay before it. Frame 0 starts at 0. Clamps to the array bounds so a
    /// sampled index past the delay list (shouldn't happen) degrades gracefully.
    static func cumulativeTime(delays: [Double], before index: Int) -> Double {
        guard index > 0 else { return 0 }
        return delays.prefix(index).reduce(0, +)
    }

    /// Evenly-spaced frame indices (first and last always included).
    static func sampleIndices(total: Int, max maxCount: Int) -> [Int] {
        guard total > maxCount else { return Array(0..<Swift.max(total, 0)) }
        guard maxCount > 1 else { return [0] }
        return (0..<maxCount).map { i in
            Int((Double(i) * Double(total - 1) / Double(maxCount - 1)).rounded())
        }
    }
}
