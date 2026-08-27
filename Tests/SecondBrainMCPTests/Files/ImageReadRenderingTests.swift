import Foundation
import MCP
import Synchronization
import Testing
@testable import second_brain_mcp

@Suite("Image read rendering consent")
struct ImageReadRenderingTests {
    @Test("Default image reads return facts and revisions without image payload or frame encoding",
          arguments: [FileFormat.png, .gif, .heic])
    func defaultReadDoesNotRender(_ format: FileFormat) async throws {
        let encoder = RenderingProbe(format: format)
        let fixture = try MediaImportBoundaryFixture(imageEncoder: encoder)
        defer { fixture.cleanup() }
        let original = Data("fixture image source".utf8)
        try original.write(to: fixture.destination(format))
        let result = try await read(fixture, format: format)
        #expect(result.isError != true)
        #expect(imageCount(result) == 0)
        #expect(encoder.encodedFrames.withLock { $0 } == 0,
                "Opt-out must skip pixel encoding, not discard encoded images afterward")
        #expect(encoder.inspections.withLock { $0 } == 1)
        let text = text(result)
        #expect(text.contains("128"))
        #expect(text.contains("render"))
        if format == .gif {
            #expect(text.contains("20 frames"))
            #expect(text.contains("2.0s"))
        }
        #expect(result.structuredContent?.objectValue?["revision"]?.stringValue
                == FileSnapshot(data: original, modifiedDate: nil).revision.rawValue)
    }

    @Test("Explicit render preserves bounded image output and omission does not inherit it",
          arguments: [FileFormat.png, .gif])
    func explicitRenderIsPerCall(_ format: FileFormat) async throws {
        let encoder = RenderingProbe(format: format)
        let fixture = try MediaImportBoundaryFixture(imageEncoder: encoder)
        defer { fixture.cleanup() }
        try Data("fixture".utf8).write(to: fixture.destination(format))
        let rendered = try await read(fixture, format: format, render: .bool(true))
        #expect(rendered.isError != true)
        #expect(imageCount(rendered) == (format == .gif ? 8 : 1))
        let callsAfterRender = encoder.encodedFrames.withLock { $0 }
        let defaultRead = try await read(fixture, format: format)
        #expect(defaultRead.isError != true)
        #expect(imageCount(defaultRead) == 0)
        #expect(encoder.encodedFrames.withLock { $0 } == callsAfterRender)
        let explicitFalse = try await read(fixture, format: format, render: .bool(false))
        #expect(explicitFalse.isError != true)
        #expect(imageCount(explicitFalse) == 0)
        #expect(encoder.encodedFrames.withLock { $0 } == callsAfterRender)
    }

    @Test("Render requires a boolean and is rejected on non-image formats")
    func invalidRenderIsActionable() async throws {
        let fixture = try MediaImportBoundaryFixture()
        defer { fixture.cleanup() }
        try Data("plain text".utf8).write(to: fixture.destination(.log))
        for format in [FileFormat.png, .log] {
            let result = try await read(fixture, format: format, render: .string("yes"))
            #expect(result.isError == true)
            #expect(text(result).contains("render"))
            #expect(text(result).contains("boolean"))
        }
        let unsupported = try await read(fixture, format: .log, render: .bool(false))
        #expect(unsupported.isError == true)
        #expect(text(unsupported).contains("render"))
        #expect(text(unsupported).contains("image"))
    }

    @Test("Opting out of rendering still validates content and image resource limits")
    func inspectionGuardsRemainActive() async throws {
        for encoder in [
            RenderingProbe(format: .gif, width: 1_000_000),
            RenderingProbe(format: .gif, frames: 10_001),
            RenderingProbe(format: .png),
        ] {
            let fixture = try MediaImportBoundaryFixture(imageEncoder: encoder)
            defer { fixture.cleanup() }
            try Data("fixture".utf8).write(to: fixture.destination(.gif))
            let result = try await read(fixture, format: .gif)
            #expect(result.isError == true)
            #expect(imageCount(result) == 0)
            #expect(encoder.encodedFrames.withLock { $0 } == 0)
        }
    }

    @Test("Image rendering opt-in is visible in tool discovery")
    func schemaAdvertisesOptIn() throws {
        let capabilities = FileCapabilities(formats: [
            .init(format: .png, operations: [.read: [.notes, .references]])
        ])
        let tool = try #require(FileToolDefinitions.build(capabilities: capabilities, readOnly: true).first)
        let render = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["render"]?.objectValue)
        #expect(render["type"]?.stringValue == "boolean")
        #expect(render["default"]?.boolValue == false)
        #expect(render["description"]?.stringValue?.contains("image") == true)
    }

    private func read(_ fixture: MediaImportBoundaryFixture, format: FileFormat,
                      render: Value? = nil) async throws -> CallTool.Result {
        var arguments: [String: Value] = [
            "format": .string(format.rawValue),
            "path": .string("notes/import." + format.rawValue),
        ]
        if let render { arguments["render"] = render }
        return try await FileToolController(readOnly: true, files: fixture.service)
            .call(.init(name: "read_file", arguments: arguments))
    }

    private func imageCount(_ result: CallTool.Result) -> Int {
        result.content.filter { if case .image = $0 { true } else { false } }.count
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    private final class RenderingProbe: ImageEncoding, Sendable {
        let format: FileFormat
        let width: Int
        let frames: Int
        let encodedFrames = Mutex(0)
        let inspections = Mutex(0)

        init(format: FileFormat, width: Int = 128, frames: Int? = nil) {
            self.format = format
            self.width = width
            self.frames = frames ?? (format == .gif ? 20 : 1)
        }

        func inspect(url: URL, maximumAnimationFrames: Int) throws -> ImageInspection {
            inspections.withLock { $0 += 1 }
            return ImageInspection(pixelWidth: width, pixelHeight: 128, format: format.rawValue,
                                   frameCount: frames,
                                   frameDelays: frames > 1 ? Array(repeating: 0.1, count: frames) : nil)
        }

        func encodeFramePNG(url: URL, frameIndex: Int, maxLongEdge: Int) throws -> Data {
            encodedFrames.withLock { $0 += 1 }
            return Data([1, 2, 3])
        }
    }
}
