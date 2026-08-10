import Foundation

/// Adapts image and video processing components to the generic file bindings.
///
/// Creation prepares normalized bytes but never writes them. Reading verifies
/// that detected media content matches the format declared by the caller before
/// returning model-compatible image content.
struct ImageFileOperations: Sendable {
    /// Request-shape errors specific to media creation.
    enum ImageOperationError: Error, CustomStringConvertible {
        /// Media creation did not provide exactly one external source path.
        case sourceRequired
        /// GIF creation did not request the supported video conversion.
        case transformRequired

        /// Human-readable media request failure.
        var description: String {
            switch self {
            case .sourceRequired: return "Image and video creation requires an external source path"
            case .transformRequired: return "GIF creation currently requires transform=video_to_gif"
            }
        }
    }

    /// Reads and normalizes images already stored in the vault.
    let imageReader: ImageReader
    /// Validates and converts external images into clean PNG data.
    let imageImporter: ImageImporter
    /// Validates and converts external videos into animated GIF data.
    let videoImporter: VideoImporter

    /// Prepares a clean PNG from an external image source.
    func preparePNG(_ request: CreateFileRequest, target: WritableFileTarget) async throws -> PreparedFileWrite {
        guard let source = request.source, request.content == nil else {
            throw ImageOperationError.sourceRequired
        }
        let image = try await imageImporter.prepare(source: source)
        var message = "Created \(target.relativePath) from "
            + "\(image.sourceFormat.rawValue.uppercased()) "
            + "\(image.width)×\(image.height) as clean PNG"
        if let note = image.note { message += "\nWarning: \(note)" }
        return PreparedFileWrite(data: image.data, output: .text(message))
    }

    /// Prepares an animated GIF from an external video source.
    func prepareVideoGIF(_ request: CreateFileRequest, target: WritableFileTarget) async throws -> PreparedFileWrite {
        guard request.transform == .videoToGIF else { throw ImageOperationError.transformRequired }
        guard let source = request.source, request.content == nil else {
            throw ImageOperationError.sourceRequired
        }
        let video = try await videoImporter.prepare(source: source)
        let message = "Created \(target.relativePath) as animated GIF \(video.width)×\(video.height), "
            + "\(String(format: "%.1f", video.durationSeconds))s, \(video.frameCount) frames, "
            + "\(Self.formatBytes(video.data.count))"
        return PreparedFileWrite(data: video.data, output: .text(message))
    }

    /// Reads an image as one native frame or a sampled animated-frame sequence.
    func read(
        _ request: ReadFileRequest,
        target: ReadableFileTarget,
        snapshot: FileSnapshot
    ) throws -> FileOperationOutput {
        let result = try imageReader.read(target: target, snapshot: snapshot)
        var contents: [VaultFileContent] = []
        let size = Self.formatBytes(result.originalBytes)

        if result.totalFrames > 1 {
            let duration = result.totalDurationSeconds.map { String(format: ", %.1fs", $0) } ?? ""
            contents.append(.text(
                "Animated GIF \(result.originalWidth)×\(result.originalHeight), \(size), "
                + "\(result.totalFrames) frames\(duration). Showing \(result.frames.count) sampled frames."
            ))
            for (offset, frame) in result.frames.enumerated() {
                let time = frame.timeOffsetSeconds.map { String(format: " at t≈%.2fs", $0) } ?? ""
                contents.append(.text("Frame \(offset + 1)/\(result.frames.count), source frame \(frame.sourceIndex)\(time)"))
                contents.append(.image(data: frame.data, mimeType: frame.mimeType))
            }
        } else {
            let treatment = result.passedThrough ? "passed through unchanged" : "re-encoded to PNG"
            contents.append(.text(
                "\(result.format.rawValue.uppercased()) \(result.originalWidth)×\(result.originalHeight), \(size) — \(treatment)"
            ))
            if let frame = result.frames.first {
                contents.append(.image(data: frame.data, mimeType: frame.mimeType))
            }
        }
        return FileOperationOutput(contents: contents)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 { return String(format: "%.1f KB", kilobytes) }
        return String(format: "%.1f MB", kilobytes / 1024)
    }
}
