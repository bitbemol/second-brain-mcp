import Foundation

/// Converts external videos into animated GIFs for generic vault persistence.
///
/// ``ExternalFileSourceValidator`` owns the external-path trust boundary and
/// ``VideoEncoding`` owns platform-specific inspection and frame encoding. This
/// actor serializes conversion work and coordinates those components using a
/// ``VideoImportConfiguration``.
///
/// The source is read without being moved, deleted, or copied into the vault.
/// Only newly encoded GIF pixels are returned in ``PreparedVideoImport``.
actor VideoImporter {
    private let sourceValidator: ExternalFileSourceValidator
    private let encoder: VideoEncoding
    private let configuration: VideoImportConfiguration
    private let conversionGate = AsyncExclusiveGate()

    /// Creates an importer with an injectable platform encoder and conversion policy.
    ///
    /// - Parameters:
    ///   - sourceValidator: Shared external-file trust boundary.
    ///   - encoder: Platform implementation used for metadata and frame work.
    ///   - configuration: Source, duration, frame, dimension, and output limits.
    init(
        sourceValidator: ExternalFileSourceValidator,
        encoder: VideoEncoding,
        configuration: VideoImportConfiguration = .default
    ) {
        self.sourceValidator = sourceValidator
        self.encoder = encoder
        self.configuration = configuration
    }

    /// Validates and converts an external video without mutating the vault.
    ///
    /// - Parameter source: Path to an external regular file. Symlinks are resolved
    ///   before trust-boundary and size checks.
    /// - Returns: Animated GIF bytes and encoded-artifact metadata ready for generic storage.
    /// - Throws: ``ExternalFileSourceValidator/ValidationError`` for filesystem
    ///   policy failures, or ``VideoImportError`` for invalid video content or output.
    func prepare(source: String) async throws -> PreparedVideoImport {
        try await conversionGate.withPermit { [self] in
            try await prepareExclusively(source: source)
        }
    }

    /// Runs one complete validation and conversion while the shared gate is held.
    private func prepareExclusively(source: String) async throws -> PreparedVideoImport {
        let validatedSource = try sourceValidator.snapshot(
            path: source,
            maximumBytes: configuration.maxSourceBytes
        )
        defer { validatedSource.remove() }

        let sourceURL = validatedSource.url
        let inspection: VideoInspection
        do {
            inspection = try await encoder.inspect(url: sourceURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch is VideoEncodingError {
            throw VideoImportError.notAVideo(source)
        }
        guard inspection.hasVideoTrack, inspection.durationSeconds > 0 else {
            throw VideoImportError.notAVideo(source)
        }
        guard inspection.durationSeconds <= configuration.maxDurationSeconds else {
            throw VideoImportError.durationTooLong(
                seconds: inspection.durationSeconds,
                limit: configuration.maxDurationSeconds
            )
        }

        let schedule = VideoFrameSchedule(
            duration: inspection.durationSeconds,
            framesPerSecond: configuration.fps,
            maximumFrames: configuration.maxFrames
        )
        let gif: PreparedVideoImport
        do {
            gif = try await encoder.makeGIF(
                url: sourceURL,
                atTimes: schedule.times,
                frameDelay: schedule.frameDelay,
                maxLongEdge: configuration.maxLongEdge,
                maximumBytes: configuration.maxOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VideoEncodingError {
            throw VideoImportError.conversionFailed("\(error)")
        }

        guard gif.data.count <= configuration.maxOutputBytes else {
            throw VideoImportError.outputTooLarge(
                bytes: gif.data.count,
                limit: configuration.maxOutputBytes
            )
        }

        return gif
    }
}
