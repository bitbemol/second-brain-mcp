import AppKit
import Foundation
import PDFKit
import Vision

/// Caller-isolated framework boundary, consumed only while PDF admission is held.
protocol PDFSearchTextDocument {
    var pageCount: Int { get }
    nonisolated(nonsending) func text(at index: Int) async throws -> String?
}

struct PDFKitSearchTextDocument: PDFSearchTextDocument {
    typealias RequestFactory = @Sendable () -> RecognizeTextRequest
    typealias RecognitionPerformer = @Sendable (CGImage, RecognizeTextRequest) async throws -> [String]

    private enum PageInput {
        case missing
        case embedded(String)
        case raster(CGImage)
    }

    private let document: PDFDocument
    private let makeRequest: RequestFactory
    private let performRecognition: RecognitionPerformer

    init?(
        data: Data,
        makeRequest: @escaping RequestFactory = { configuredRecognitionRequest() },
        performRecognition: @escaping RecognitionPerformer = { image, request in
            let observations = try await request.perform(on: image, orientation: nil)
            return autoreleasepool {
                observations.compactMap { $0.topCandidates(1).first?.string }
            }
        }
    ) {
        guard let document = PDFDocument(data: data) else { return nil }
        self.document = document
        self.makeRequest = makeRequest
        self.performRecognition = performRecognition
    }

    var pageCount: Int { document.pageCount }

    /// Preserve the legacy reader's effective settings, including its zero text-height cutoff.
    static func configuredRecognitionRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeightFraction = 0
        for (stage, devices) in request.supportedComputeStageDevices {
            if let cpu = devices.first(where: {
                if case .cpu = $0 { return true }
                return false
            }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        return request
    }

    nonisolated(nonsending) func text(at index: Int) async throws -> String? {
        let input = try autoreleasepool { try preparePage(at: index) }
        switch input {
        case .missing:
            return nil
        case .embedded(let text):
            return text
        case .raster(let image):
            // Only the immutable raster crosses this await; PDFKit stays single-reader.
            return try await recognizedText(in: image)
        }
    }

    private func preparePage(at index: Int) throws -> PageInput {
        try Task.checkCancellation()
        guard let page = document.page(at: index) else { return .missing }
        let embedded = page.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try Task.checkCancellation()
        if !embedded.isEmpty { return .embedded(embedded) }
        let image = page.thumbnail(of: NSSize(width: 1_800, height: 1_800), for: .mediaBox)
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            return .embedded("")
        }
        try Task.checkCancellation()
        return .raster(cgImage)
    }

    private nonisolated(nonsending) func recognizedText(in image: CGImage) async throws -> String {
        try Task.checkCancellation()
        let request = makeRequest()
        try Task.checkCancellation()
        do {
            let strings = try await performRecognition(image, request)
            try Task.checkCancellation()
            return strings.joined(separator: "\n")
        } catch {
            // Vision may finish with its own error after the parent task was cancelled.
            try Task.checkCancellation()
            throw error
        }
    }
}
