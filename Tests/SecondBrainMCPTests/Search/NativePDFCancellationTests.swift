import CoreGraphics
import CryptoKit
import Foundation
import Synchronization
import Testing
import Vision
@testable import second_brain_mcp

@Suite("Native PDF cancellation forwarding")
struct NativePDFCancellationTests {
    @Test("Cancelling awaited OCR keeps its permit until the native call unwinds")
    func activeRecognitionReceivesCancellation() async throws {
        let fixture = try NativeCancellationFixture()
        defer { fixture.remove() }
        let hold = NativeRecognitionHold()
        defer { hold.release() }
        let gate = AsyncExclusiveGate(maximumWaiters: 2)
        let admission = PDFReadAdmission(gate: gate)
        let provider = fixture.provider(admission: admission) { _, _ in
            await withTaskCancellationHandler {
                await hold.perform()
                return ["Late native result"]
            } onCancel: {
                hold.recordCancellation()
            }
        }
        let operation = Task { try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot) }
        let entered = await eventually { hold.entered }
        operation.cancel()
        let forwarded = await eventually { hold.cancelCount == 1 }
        let successorEntered = Mutex(false)
        let successor = Task {
            try await admission.withPermit { successorEntered.withLock { $0 = true } }
        }
        let queued = await eventuallyAsync { await gate.waitingCount == 1 }
        let releasedEarly = successorEntered.withLock { $0 }
        hold.release()
        let outcome = await operation.result
        try await successor.value

        #expect(entered)
        #expect(forwarded, "The awaited native operation must inherit task cancellation")
        #expect(queued)
        #expect(!releasedEarly, "Admission stays held until the public native await returns")
        #expect(hold.performCount == 1, "No later PDF page may begin after cancellation")
        #expect(successorEntered.withLock { $0 })
        expectCancelled(outcome)
        #expect(!fixture.hasPublishedCache)
    }

    @Test("A cooperative awaited performer receives the caller task cancellation")
    func cooperativeRecognitionCancels() async throws {
        let fixture = try NativeCancellationFixture()
        defer { fixture.remove() }
        let performed = Mutex(0)
        let cancelledInside = Mutex(false)
        let provider = fixture.provider(admission: PDFReadAdmission()) { _, _ in
            performed.withLock { $0 += 1 }
            do {
                try await Task.sleep(for: .seconds(5))
                return ["Unexpected completion"]
            } catch {
                cancelledInside.withLock { $0 = Task.isCancelled }
                throw error
            }
        }
        let operation = Task { try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot) }
        let entered = await eventually { performed.withLock { $0 } == 1 }
        operation.cancel()
        let outcome = await operation.result
        #expect(entered)
        #expect(cancelledInside.withLock { $0 })
        #expect(performed.withLock { $0 } == 1)
        expectCancelled(outcome)
        #expect(!fixture.hasPublishedCache)
    }

    @Test("Cancellation during request creation prevents starting native recognition")
    func cancellationBeforeRequestInstallationPreventsPerform() async throws {
        let fixture = try NativeCancellationFixture()
        defer { fixture.remove() }
        let performed = Mutex(0)
        let provider = fixture.provider(
            admission: PDFReadAdmission(),
            makeRequest: {
                withUnsafeCurrentTask { $0?.cancel() }
                return PDFKitSearchTextDocument.configuredRecognitionRequest()
            },
            perform: { _, _ in
                performed.withLock { $0 += 1 }
                return ["Unexpected"]
            }
        )
        let operation = Task { try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot) }
        let outcome = await operation.result
        #expect(performed.withLock { $0 } == 0)
        expectCancelled(outcome)
        #expect(!fixture.hasPublishedCache)
    }

    @Test("Late cancellation does not re-enter a completed native operation")
    func completedRequestIsNotCancelled() async throws {
        let fixture = try NativeCancellationFixture()
        defer { fixture.remove() }
        let cancellations = Mutex(0)
        let provider = fixture.provider(admission: PDFReadAdmission()) { _, _ in
            await withTaskCancellationHandler {
                ["Completed"]
            } onCancel: {
                cancellations.withLock { $0 += 1 }
            }
        }
        let operation = Task { try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot) }
        let atoms = try await operation.value
        operation.cancel()
        #expect(atoms.map(\.text) == ["Completed", "Completed"])
        #expect(cancellations.withLock { $0 } == 0)
        #expect(fixture.hasPublishedCache)
    }

    @Test("A native failure after task cancellation remains CancellationError")
    func nativeFailureAfterCancellationIsNotAFormatError() async throws {
        let fixture = try NativeCancellationFixture()
        defer { fixture.remove() }
        let hold = NativeRecognitionHold()
        defer { hold.release() }
        let provider = fixture.provider(admission: PDFReadAdmission()) { _, _ in
            try await withTaskCancellationHandler {
                await hold.perform()
                throw NSError(domain: "SyntheticNativeFailure", code: 17)
            } onCancel: {
                hold.recordCancellation()
            }
        }
        let operation = Task { try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot) }
        let entered = await eventually { hold.entered }
        operation.cancel()
        let forwarded = await eventually { hold.cancelCount == 1 }
        hold.release()
        let outcome = await operation.result
        #expect(entered && forwarded)
        expectCancelled(outcome)
        #expect(hold.performCount == 1)
        #expect(!fixture.hasPublishedCache)
    }

    @Test("The immutable page raster survives suspension after its autorelease scope")
    func rasterIsRetainedAcrossNativeAwait() async throws {
        let fixture = try NativeCancellationFixture()
        defer { fixture.remove() }
        let hold = NativeRecognitionHold()
        defer { hold.release() }
        let checked = Mutex(0)
        let provider = fixture.provider(admission: PDFReadAdmission()) { image, _ in
            let before = try rasterDigest(image)
            await hold.perform()
            let after = try rasterDigest(image)
            #expect(before == after)
            #expect(image.width > 0 && image.width <= 1_800)
            #expect(image.height > 0 && image.height <= 1_800)
            checked.withLock { $0 += 1 }
            return ["Retained raster"]
        }
        let operation = Task { try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot) }
        let entered = await eventually { hold.entered }
        hold.release()
        let atoms = try await operation.value
        #expect(entered)
        #expect(checked.withLock { $0 } == 2)
        #expect(atoms.map(\.text) == ["Retained raster", "Retained raster"])
    }

    @Test("Embedded PDF text bypasses OCR")
    func embeddedTextSkipsRecognition() async throws {
        let fixture = try NativeCancellationFixture(pages: ["Embedded first", "Embedded second"])
        defer { fixture.remove() }
        let performed = Mutex(0)
        let provider = fixture.provider(admission: PDFReadAdmission()) { _, _ in
            performed.withLock { $0 += 1 }
            return ["Unexpected OCR"]
        }
        let atoms = try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot)
        #expect(atoms.map(\.text) == ["Embedded first", "Embedded second"])
        #expect(performed.withLock { $0 } == 0)
    }

    @Test("OCR assigns a supported CPU at every stage that advertises one")
    func supportedCPUStagesAreSelected() async throws {
        let available = PDFKitSearchTextDocument.configuredRecognitionRequest().supportedComputeStageDevices
        let cpuStages = available.filter { _, devices in
            devices.contains { if case .cpu = $0 { return true }; return false }
        }
        let fixture = try NativeCancellationFixture()
        defer { fixture.remove() }
        let checked = Mutex(0)
        let provider = fixture.provider(admission: PDFReadAdmission()) { _, request in
            for (stage, devices) in request.supportedComputeStageDevices {
                if devices.contains(where: { if case .cpu = $0 { return true }; return false }) {
                    let selectedCPU: Bool
                    if case .cpu? = request.computeDevice(for: stage) {
                        selectedCPU = true
                    } else {
                        selectedCPU = false
                    }
                    #expect(selectedCPU, "Advertised CPU stage must not retain automatic device selection")
                    checked.withLock { $0 += 1 }
                } else {
                    #expect(request.computeDevice(for: stage) == nil)
                }
            }
            return ["CPU-selected"]
        }
        let atoms = try await provider.atoms(for: fixture.target, snapshot: fixture.snapshot)
        #expect(atoms.map(\.text) == ["CPU-selected", "CPU-selected"])
        #expect(checked.withLock { $0 } == cpuStages.count * 2)
    }

    @Test("Modern OCR preserves the effective legacy request configuration")
    func modernConfigurationMatchesLegacy() {
        let legacy = VNRecognizeTextRequest()
        legacy.recognitionLevel = .accurate
        legacy.usesLanguageCorrection = true
        let modern = PDFKitSearchTextDocument.configuredRecognitionRequest()
        #expect(legacy.revision == VNRecognizeTextRequestRevision3)
        #expect(modern.revision == .revision3)
        #expect(modern.recognitionLevel == .accurate)
        #expect(modern.usesLanguageCorrection == legacy.usesLanguageCorrection)
        #expect(modern.automaticallyDetectsLanguage == legacy.automaticallyDetectsLanguage)
        #expect(modern.minimumTextHeightFraction == legacy.minimumTextHeight)
        #expect(modern.customWords == legacy.customWords)
        let legacyLanguages = legacy.recognitionLanguages.map { languageKey(Locale.Language(identifier: $0)) }
        let modernLanguages = modern.recognitionLanguages.map(languageKey)
        #expect(modernLanguages == legacyLanguages, "Do not silently narrow recognized languages")
    }

    private func languageKey(_ language: Locale.Language) -> [String?] {
        [language.languageCode?.identifier, language.script?.identifier, language.region?.identifier]
    }

    private func expectCancelled(_ result: Result<[SearchAtom], any Error>) {
        guard case .failure(let error) = result else {
            Issue.record("Cancelled OCR unexpectedly returned searchable atoms")
            return
        }
        #expect(error is CancellationError)
    }

    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private func eventuallyAsync(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}

private func rasterDigest(_ image: CGImage) throws -> SHA256.Digest {
    let bytes = try #require(image.dataProvider?.data)
    return SHA256.hash(data: bytes as Data)
}

/// A single owned suspension point. Cancellation is observed without returning early.
private final class NativeRecognitionHold: Sendable {
    private struct State {
        var calls = 0
        var cancellations = 0
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    var entered: Bool { state.withLock { $0.calls > 0 } }
    var performCount: Int { state.withLock { $0.calls } }
    var cancelCount: Int { state.withLock { $0.cancellations } }

    func perform() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { value in
                value.calls += 1
                if value.released { return true }
                precondition(value.waiter == nil)
                value.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func recordCancellation() { state.withLock { $0.cancellations += 1 } }

    func release() {
        let waiter = state.withLock { value in
            value.released = true
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

private struct NativeCancellationFixture: Sendable {
    let root: URL
    let cache: URL
    let target: ReadableFileTarget
    let snapshot: FileSnapshot

    init(pages: [String] = ["", ""]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = root.appendingPathComponent("cache")
        let references = root.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let data = try generatedSearchPDF(pages: pages)
        try data.write(to: references.appendingPathComponent("blank.pdf"))
        target = try ReadableFileTarget.resolve(
            path: "references/blank.pdf", format: .pdf, vaultPath: root.path
        )
        snapshot = FileSnapshot(data: data, modifiedDate: nil)
    }

    func provider(
        admission: PDFReadAdmission,
        makeRequest: @escaping PDFKitSearchTextDocument.RequestFactory = {
            PDFKitSearchTextDocument.configuredRecognitionRequest()
        },
        perform: @escaping PDFKitSearchTextDocument.RecognitionPerformer
    ) -> PDFSearchAtomProvider {
        PDFSearchAtomProvider(cacheRoot: cache, admission: admission) { data in
            PDFKitSearchTextDocument(data: data, makeRequest: makeRequest, performRecognition: perform)
        }
    }

    var hasPublishedCache: Bool {
        guard let enumerator = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)
        else { return false }
        return enumerator.contains { ($0 as? URL)?.pathExtension == "json" }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
