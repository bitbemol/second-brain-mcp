#if canImport(ImageIO)
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// macOS `ImageEncoding` backed by ImageIO / CoreGraphics. In-process, zero deps
/// (system framework), same trust surface as the PDFKit path already in the server.
/// No `Process()` — stays within Rule 4.
struct CoreGraphicsImageEncoder: ImageEncoding {

    enum EncoderError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case missingDimensions(String)
        case decodeFailed(String)
        case encodeFailed(String)

        var description: String {
            switch self {
            case .cannotOpen(let path): return "Cannot open image: \(path)"
            case .missingDimensions(let path): return "Image has no readable dimensions: \(path)"
            case .decodeFailed(let path): return "Failed to decode image: \(path)"
            case .encodeFailed(let path): return "Failed to encode image: \(path)"
            }
        }
    }

    func inspect(url: URL) throws -> ImageInspection {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EncoderError.cannotOpen(url.lastPathComponent)
        }
        // Properties only — no pixel decode. This is what bounds the bomb risk.
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw EncoderError.missingDimensions(url.lastPathComponent)
        }

        let format: String
        if let uti = CGImageSourceGetType(source),
           let ext = UTType(uti as String)?.preferredFilenameExtension {
            format = ext.lowercased()
        } else {
            format = url.pathExtension.lowercased()
        }

        // Frame count is read from the index count, not by decoding frames.
        let frameCount = max(CGImageSourceGetCount(source), 1)

        return ImageInspection(pixelWidth: width, pixelHeight: height, format: format, frameCount: frameCount)
    }

    func encodeFramePNG(url: URL, frameIndex: Int, maxLongEdge: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EncoderError.cannotOpen(url.lastPathComponent)
        }
        let count = max(CGImageSourceGetCount(source), 1)
        let index = min(max(frameIndex, 0), count - 1)

        // Decode the requested frame straight to a bounded size — ImageIO
        // downsamples during decode, so we never materialize the full-resolution
        // bitmap.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw EncoderError.decodeFailed(url.lastPathComponent)
        }

        // Re-encode to PNG (lossless — keeps text crisp, preserves alpha; drops EXIF).
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw EncoderError.encodeFailed(url.lastPathComponent)
        }
        return data as Data
    }
}
#endif
