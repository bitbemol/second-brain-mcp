import Foundation

/// Imports an external video **into the vault as an animated GIF**. The video twin
/// of `ImageImporter`, with the same source trust model: it is the only tool
/// besides `add_image` that reads a path **outside** the vault sandbox, and that's
/// deliberate. The source is canonicalized and required to be a regular file, the
/// resolved target is size-capped, and a source that resolves inside the vault is
/// refused — `add_video` imports *external* files only. The **decode is the gate**:
/// a file that isn't a real, decodable video has no video track and is rejected
/// before anything is written. Only the assembled GIF's pixels land in the vault;
/// audio is dropped and no source bytes are copied verbatim.
///
/// Why a GIF and not the original container: `read_image` already samples animated
/// GIFs into a timed PNG frame bundle, so storing the recording as a GIF lets the
/// model "watch" it — and the GIF plays inline in Obsidian. The conversion is done
/// in-process with AVFoundation + ImageIO (see `AVFoundationVideoEncoder`); there
/// is no ffmpeg / `Process()` (Rule 4).
///
/// Actor because the conversion + write must be serialized, mirroring
/// `ImageImporter` / `VaultManager`. All policy lives here; the platform-bound
/// frame work sits behind `VideoEncoding`, so this type stays unit-testable with a
/// fake encoder. The source is only ever **read** — never moved, deleted, or
/// otherwise touched. The vault is this server's entire write domain.
actor VideoImporter {

    enum VideoImporterError: Error, CustomStringConvertible {
        case invalidDestination(String)
        case sourceNotFound(String)
        case sourceNotAFile(String)
        case sourceInsideVault(String)
        case sourceTooLarge(bytes: Int, limit: Int)
        case notAVideo(String)
        case durationTooLong(seconds: Double, limit: Double)
        case destinationExists(String)
        case outputTooLarge(bytes: Int, limit: Int)
        case conversionFailed(String)
        case writeFailed(String, underlying: String)

        var description: String {
            switch self {
            case .invalidDestination(let reason): return "Invalid destination: \(reason)"
            case .sourceNotFound(let path): return "Source file not found: \(path)"
            case .sourceNotAFile(let path): return "Source is not a regular file: \(path)"
            case .sourceInsideVault(let path): return "Source is inside the vault — add_video imports external files only: \(path)"
            case .sourceTooLarge(let bytes, let limit): return "Source video is too large: \(bytes) bytes (limit \(limit))"
            case .notAVideo(let path): return "Source is not a readable video: \(path)"
            case .durationTooLong(let seconds, let limit): return "Video is too long: \(String(format: "%.0f", seconds))s (limit \(String(format: "%.0f", limit))s)"
            case .destinationExists(let path): return "Destination already exists: \(path)"
            case .outputTooLarge(let bytes, let limit): return "Resulting GIF is too large: \(bytes) bytes (limit \(limit)) — try a shorter clip or lower fidelity"
            case .conversionFailed(let reason): return "Video conversion failed: \(reason)"
            case .writeFailed(let path, let underlying): return "Failed to write \(path): \(underlying)"
            }
        }
    }

    /// Balanced tuning. Internal struct so tests can dial the caps down; the tool
    /// surface keeps these fixed (a minimal `source` + `destination` API).
    struct Config: Sendable {
        /// Target sampling rate for a short clip. A long clip is sampled below this
        /// so the frame count stays within `maxFrames`.
        let fps: Double
        /// Long-edge cap per GIF frame (downscale-on-decode box).
        let maxLongEdge: Int
        /// Hard ceiling on the number of sampled frames — bounds work and output
        /// size regardless of how long the source is.
        let maxFrames: Int
        /// Hard file-size reject on the source, applied before it is opened.
        let maxSourceBytes: Int
        /// Reject a clip longer than this (seconds) before converting.
        let maxDurationSeconds: Double
        /// The real backstop: reject the assembled GIF if it exceeds this. GIFs
        /// don't inter-frame compress well, so this — not the source cap — is what
        /// keeps a vault attachment a sane size.
        let maxOutputBytes: Int

        static let `default` = Config(
            fps: 10,
            maxLongEdge: 1080,
            maxFrames: 120,
            maxSourceBytes: 512 * 1024 * 1024,
            maxDurationSeconds: 1800,
            maxOutputBytes: 50 * 1024 * 1024
        )
    }

    struct ImportResult: Sendable {
        let destination: String      // final vault-relative path (always .gif)
        let width: Int
        let height: Int
        let durationSeconds: Double
        let frameCount: Int
        let fps: Double              // effective playback rate (frameCount / duration)
        let bytesWritten: Int
    }

    private let vaultPath: String
    private let encoder: VideoEncoding
    private let config: Config

    init(vaultPath: String, encoder: VideoEncoding, config: Config = .default) {
        self.vaultPath = vaultPath
        self.encoder = encoder
        self.config = config
    }

    /// Validate `source` as a real video and import it into the vault at
    /// `destination` (normalized to a `.gif`), converting it to a sampled animated
    /// GIF. Purely additive: the source is only ever **read**.
    func add(source: String, destination: String) async throws -> ImportResult {
        // 1. Destination (vault side) — under notes/, normalized to .gif, path-gated,
        //    and must not already exist (no clobber).
        let finalRel = Self.normalizedDestination(destination)
        guard finalRel.hasPrefix("notes/") else {
            throw VideoImporterError.invalidDestination("Destination must be within notes/: \(destination)")
        }
        let resolvedDest: String
        do {
            resolvedDest = try PathValidator.resolve(relativePath: finalRel, root: vaultPath, allowedExtensions: ["gif"])
        } catch {
            throw VideoImporterError.invalidDestination("\(error)")
        }
        guard !FileManager.default.fileExists(atPath: resolvedDest) else {
            throw VideoImporterError.destinationExists(finalRel)
        }

        // 2. Source (external). Canonicalize FIRST — resolve symlinks so every check
        //    below applies to the *real* target, not a symlink that could point at a
        //    file past the size cap, at a device/FIFO, or back inside the vault.
        let src = URL(fileURLWithPath: source.trimmingCharacters(in: .whitespaces)).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: src) else {
            throw VideoImporterError.sourceNotFound(source)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: src)
        // Must be a regular file — rejects directories, FIFOs, sockets, and devices.
        // (A FIFO source would otherwise block the decoder and stall the actor.)
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw VideoImporterError.sourceNotAFile(source)
        }
        // Size cap on the *resolved* target (a symlink stats tiny, hiding a huge target).
        let bytes = (attrs[.size] as? Int) ?? 0
        guard bytes <= config.maxSourceBytes else {
            throw VideoImporterError.sourceTooLarge(bytes: bytes, limit: config.maxSourceBytes)
        }
        // add_video imports EXTERNAL files. A source already inside the vault is
        // refused — manage existing vault attachments with the vault's own tools.
        // (Shared with add_image: same external-only invariant.)
        guard !ImageImporter.isInsideVault(src, vaultPath: vaultPath) else {
            throw VideoImporterError.sourceInsideVault(source)
        }

        // 3. Prove it's a real video and bound its duration — the gate on the
        //    external path. Inspection reads metadata only, no frame decode.
        let srcURL = URL(fileURLWithPath: src)
        let info: VideoInspection
        do {
            info = try await encoder.inspect(url: srcURL)
        } catch {
            throw VideoImporterError.notAVideo(source)
        }
        guard info.hasVideoTrack, info.durationSeconds > 0 else {
            throw VideoImporterError.notAVideo(source)
        }
        guard info.durationSeconds <= config.maxDurationSeconds else {
            throw VideoImporterError.durationTooLong(seconds: info.durationSeconds, limit: config.maxDurationSeconds)
        }

        // 4. Compute the frame schedule and assemble the GIF.
        let schedule = Self.frameSchedule(duration: info.durationSeconds, fps: config.fps, maxFrames: config.maxFrames)
        let gif: Data
        do {
            gif = try await encoder.makeGIF(
                url: srcURL,
                atTimes: schedule.times,
                frameDelay: schedule.frameDelay,
                maxLongEdge: config.maxLongEdge
            )
        } catch {
            throw VideoImporterError.conversionFailed("\(error)")
        }

        // 5. Output-size guard — the real backstop. Reject before writing.
        guard gif.count <= config.maxOutputBytes else {
            throw VideoImporterError.outputTooLarge(bytes: gif.count, limit: config.maxOutputBytes)
        }

        // 6. Write into the vault.
        let parent = (resolvedDest as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try gif.write(to: URL(fileURLWithPath: resolvedDest), options: .atomic)
        } catch {
            throw VideoImporterError.writeFailed(finalRel, underlying: error.localizedDescription)
        }

        let frameCount = schedule.times.count
        let effectiveFPS = info.durationSeconds > 0 ? Double(frameCount) / info.durationSeconds : config.fps
        return ImportResult(
            destination: finalRel,
            width: info.width,
            height: info.height,
            durationSeconds: info.durationSeconds,
            frameCount: frameCount,
            fps: effectiveFPS,
            bytesWritten: gif.count
        )
    }

    /// Pure frame-schedule math. Sample `frameCount = min(ceil(duration × fps),
    /// maxFrames)` frames (always ≥ 1), evenly spaced across `[0, duration)`, each
    /// shown for `duration / frameCount` seconds so GIF playback runs at ~real-time.
    /// A short clip gets full `fps`; a long one spreads the cap across the whole
    /// video. Static and side-effect-free so it can be unit-tested directly.
    static func frameSchedule(duration: Double, fps: Double, maxFrames: Int) -> (times: [Double], frameDelay: Double) {
        let safeDuration = max(duration, 0)
        let rawCount = Int((safeDuration * fps).rounded(.up))
        let frameCount = max(1, min(rawCount, max(maxFrames, 1)))
        let frameDelay = safeDuration / Double(frameCount)
        let times = (0..<frameCount).map { Double($0) * safeDuration / Double(frameCount) }
        return (times, frameDelay)
    }

    /// We always store a GIF, so force a `.gif` extension on the destination
    /// (replacing any other) and trim surrounding whitespace.
    static func normalizedDestination(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        let noExt = (trimmed as NSString).deletingPathExtension
        return noExt.isEmpty ? trimmed : noExt + ".gif"
    }
}
