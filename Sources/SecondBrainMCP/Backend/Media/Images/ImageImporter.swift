import Foundation

/// Prepares an image **from an arbitrary path on disk** for vault creation,
/// re-encoding it to a clean PNG. Actor isolation serializes potentially expensive
/// external decoding; the actor never mutates the vault or the source file.
///
/// ``ExternalFileSourceValidator`` establishes the filesystem trust boundary;
/// image decode is the content gate on the resulting source. A renamed script,
/// archive, or other non-image will not decode via `ImageEncoding.inspect`, so it
/// is rejected before prepared output is returned. Re-encoding to PNG guarantees
/// that only pixels reach generic persistence — EXIF, trailing bytes, and any
/// appended or polyglot payload are stripped. Re-encoding is a deliberate choice
/// over a verbatim copy; the codebase's "reject, don't sanitize" rule is about
/// hostile *paths*, whereas decoding and re-encoding pixels is the same
/// normalization image reads use.
actor ImageImporter {
    private let sourceValidator: ExternalFileSourceValidator
    private let encoder: ImageEncoding
    private let limits: ImageLimits

    /// Creates an importer with an injectable platform encoder and policy limits.
    ///
    /// - Parameters:
    ///   - sourceValidator: Shared external-file trust boundary.
    ///   - encoder: Platform implementation used for metadata and pixel work.
    ///   - limits: Source-size, pixel-count, and output-dimension limits.
    init(
        sourceValidator: ExternalFileSourceValidator,
        encoder: ImageEncoding,
        limits: ImageLimits = .default
    ) {
        self.sourceValidator = sourceValidator
        self.encoder = encoder
        self.limits = limits
    }

    /// Validates and normalizes an external image without mutating the vault.
    ///
    /// - Parameter source: Path to an external regular file. Symlinks are resolved
    ///   before trust-boundary and size checks.
    /// - Returns: Clean PNG bytes and source metadata ready for generic storage.
    /// - Throws: ``ExternalFileSourceValidator/ValidationError`` for filesystem
    ///   policy failures, ``ImageResourcePolicy/ValidationError`` for unsafe image
    ///   dimensions, or ``ImageImportError`` when image content is unsupported.
    func prepare(source: String) throws -> PreparedImageImport {
        let validatedSource = try sourceValidator.snapshot(
            path: source,
            maximumBytes: limits.maxFileBytes
        )
        defer { validatedSource.remove() }

        // Prove it is a supported image without decoding pixels, then apply the
        // megapixel guard before any expensive decode work.
        let sourceURL = validatedSource.url
        let inspection: ImageInspection
        do {
            inspection = try encoder.inspect(
                url: sourceURL,
                maximumAnimationFrames: limits.gifMaxSourceFrames
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImageEncodingError {
            switch error {
            case .tooManyFrames(let count, let limit):
                throw ImageResourcePolicy.ValidationError.tooManyAnimationFrames(count: count, limit: limit)
            case .cannotOpen, .missingDimensions, .decodeFailed, .encodeFailed:
                throw ImageImportError.notAnImage(source)
            }
        }
        guard let sourceFormat = FileFormat.imageFormat(
            matching: inspection.format
        ) else {
            throw ImageImportError.unsupportedFormat(inspection.format)
        }
        try ImageResourcePolicy.validate(
            inspection,
            maximumMegapixels: limits.maxMegapixels,
            maximumAnimationFrames: limits.gifMaxSourceFrames
        )

        // Re-encode to a clean PNG and cap the long edge to the same practical
        // vision size used by ImageReader. Decoding strips non-pixel data; the
        // cap avoids storing huge images that will only be downscaled on read.
        let longEdge = max(inspection.pixelWidth, inspection.pixelHeight)
        let storedLongEdge = min(longEdge, limits.maxLongEdge)
        let png: Data
        do {
            png = try encoder.encodeFramePNG(
                url: sourceURL,
                frameIndex: 0,
                maxLongEdge: storedLongEdge
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImageEncodingError {
            switch error {
            case .tooManyFrames(let count, let limit):
                throw ImageResourcePolicy.ValidationError.tooManyAnimationFrames(count: count, limit: limit)
            case .cannotOpen, .missingDimensions, .decodeFailed, .encodeFailed:
                throw ImageImportError.notAnImage(source)
            }
        }
        try FileResourcePolicy.validate(
            bytes: png.count,
            format: .png,
            path: "prepared PNG",
            maximumBytes: limits.maxFileBytes
        )

        var notes: [String] = []
        if inspection.frameCount > 1 {
            notes.append("source was an animated image; imported its first frame only")
        }
        if longEdge > storedLongEdge {
            notes.append("resized long edge from \(longEdge)px to \(storedLongEdge)px")
        }
        return PreparedImageImport(
            data: png,
            sourceFormat: sourceFormat,
            width: inspection.pixelWidth,
            height: inspection.pixelHeight,
            note: notes.isEmpty ? nil : notes.joined(separator: "; ")
        )
    }
}
