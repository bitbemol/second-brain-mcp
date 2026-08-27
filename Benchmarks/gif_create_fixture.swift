import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Synthetic benchmark setup only; never linked into the MCP executable.
@main
struct GIFCreateFixture {
    enum Failure: Error { case invalidInput, encoding }
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalidInput }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: outputURL.path),
              let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 64, image.height == 48 else { throw Failure.invalidInput }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 48,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else { throw Failure.encoding }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.encoding }
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now + .seconds(30)
        for index in 0..<259 {
            while !input.isReadyForMoreMediaData {
                guard ContinuousClock.now < deadline, writer.status == .writing
                else { writer.cancelWriting(); throw Failure.encoding }
                try await Task.sleep(for: .milliseconds(1))
            }
            var optional: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB,
                                      attributes as CFDictionary, &optional) == kCVReturnSuccess,
                  let buffer = optional else { throw Failure.encoding }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: 64, height: 48,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) else { throw Failure.encoding }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48))
            context.setFillColor(CGColor(red: CGFloat(index % 256) / 255,
                                         green: CGFloat(index / 256), blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10))
            else { throw Failure.encoding }
        }
        writer.endSession(atSourceTime: CMTime(value: 259, timescale: 10))
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw Failure.encoding }
        print("Generated 64x48 video: 259 frames, 10fps, 25.9 seconds")
    }
}
