import Foundation

/// Reads image files from the vault for viewing. Sendable struct — stateless,
/// no actor isolation needed; the platform work is delegated to an injected
/// `ImageEncoding`; transport decisions are delegated to ``ImageReadPlan``.
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
///   client reads them as a *timed* sequence (it cannot perceive GIF motion — or
///   pacing — from a single image).
/// - Decode bombs are rejected by **inspecting dimensions before decoding pixels**.
struct ImageReader: Sendable {
    private let encoder: ImageEncoding
    private let limits: ImageLimits

    /// Creates an image reader with an injectable encoder and policy limits.
    ///
    /// - Parameters:
    ///   - encoder: Platform implementation used for metadata and pixel work.
    ///   - limits: File-size, pixel-count, sampling, and dimension limits.
    init(encoder: ImageEncoding, limits: ImageLimits = .default) {
        self.encoder = encoder
        self.limits = limits
    }

    /// Reads an image from `notes/` or `references/`.
    ///
    /// - Parameter target: Path and extension-validated vault image target.
    /// - Returns: Original metadata plus transport-ready frame content.
    /// - Throws: ``VaultFileInspector/InspectionError``,
    ///   ``FileResourcePolicy/Violation``, ``ImageResourcePolicy/ValidationError``,
    ///   ``FileRoutingError/contentMismatch(path:declared:detected:)``, or an
    ///   encoder error when image metadata or pixels cannot be decoded.
    func read(target: ReadableFileTarget) throws -> ImageReadResult {
        let opened = try VaultFileInspector.snapshot(
            target,
            maximumBytes: limits.maxFileBytes
        )
        return try read(
            target: target,
            snapshot: FileSnapshot(
                data: opened.data,
                modifiedDate: opened.metadata.modificationDate
            )
        )
    }

    /// Reads transport content exclusively from the immutable service snapshot.
    func read(
        target: ReadableFileTarget,
        snapshot: FileSnapshot,
        render: Bool = true
    ) throws -> ImageReadResult {
        // 1. Size guard before passing captured bytes to a decoder.
        try FileResourcePolicy.validate(
            bytes: snapshot.data.count,
            format: target.format,
            path: target.relativePath,
            maximumBytes: limits.maxFileBytes
        )
        let temporary = try VaultFileInspector.temporarySnapshot(
            snapshot,
            target: target
        )
        defer { temporary.remove() }
        let bytes = snapshot.data.count
        let url = temporary.url

        // 2. Inspect dimensions WITHOUT decoding pixels (decode-bomb guard).
        let info = try encoder.inspect(
            url: url,
            maximumAnimationFrames: limits.gifMaxSourceFrames
        )
        guard let detectedFormat = FileFormat.imageFormat(matching: info.format),
              detectedFormat == target.format else {
            throw FileRoutingError.contentMismatch(
                path: target.relativePath,
                declared: target.format,
                detected: info.format
            )
        }
        try ImageResourcePolicy.validate(
            info,
            maximumMegapixels: limits.maxMegapixels,
            maximumAnimationFrames: limits.gifMaxSourceFrames
        )

        // 3. Build the side-effect-free transport plan, then execute its selected
        //    source reads or bounded frame encodes.
        let plan = ImageReadPlan(
            format: detectedFormat,
            inspection: info,
            limits: limits
        )
        let frames: [ImageReadFrame]
        switch render ? plan.encoding : nil {
        case nil:
            frames = []
        case .sourceBytes(let mimeType)?:
            frames = plan.selections.map { selection in
                ImageReadFrame(
                    data: snapshot.data,
                    mimeType: mimeType,
                    sourceIndex: selection.sourceIndex,
                    timeOffsetSeconds: selection.timeOffsetSeconds
                )
            }
        case .png(let maximumLongEdge)?:
            var encodedFrames: [ImageReadFrame] = []
            encodedFrames.reserveCapacity(plan.selections.count)
            var encodedBytes = 0
            for selection in plan.selections {
                try Task.checkCancellation()
                let data = try encoder.encodeFramePNG(
                    url: url,
                    frameIndex: selection.sourceIndex,
                    maxLongEdge: maximumLongEdge
                )
                try Task.checkCancellation()
                let (aggregateBytes, overflow) = encodedBytes
                    .addingReportingOverflow(data.count)
                guard !overflow, aggregateBytes <= limits.maxFileBytes else {
                    throw FileResourcePolicy.Violation(
                        path: "\(target.relativePath) rendered image output",
                        bytes: overflow ? Int.max : aggregateBytes,
                        limit: limits.maxFileBytes
                    )
                }
                encodedBytes = aggregateBytes
                encodedFrames.append(ImageReadFrame(
                    data: data,
                    mimeType: "image/png",
                    sourceIndex: selection.sourceIndex,
                    timeOffsetSeconds: selection.timeOffsetSeconds
                ))
            }
            frames = encodedFrames
        }

        return ImageReadResult(
            relativePath: target.relativePath,
            format: detectedFormat,
            originalWidth: info.pixelWidth,
            originalHeight: info.pixelHeight,
            originalBytes: bytes,
            totalFrames: plan.totalFrames,
            frames: frames,
            passedThrough: render && plan.passedThrough,
            totalDurationSeconds: plan.totalDurationSeconds
        )
    }
}
