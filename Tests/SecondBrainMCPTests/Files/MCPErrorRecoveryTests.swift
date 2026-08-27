import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("Bounded actionable MCP errors")
struct MCPErrorRecoveryTests {
    private let marker = "PRIVATE_DIAGNOSTIC_MARKER"

    @Test("Real text, JSON, and size validation failures give actionable diagnostics")
    func validationFailuresRemainActionable() async throws {
        let failures: [(any Error, String)] = [
            (try capturedError {
                _ = try TextFileSupport.apply(
                    [TextReplacement(oldText: "absent", newText: "replacement")], to: "original"
                )
            }, "text not found"),
            (try capturedError {
                _ = try TextFileSupport.apply(
                    [TextReplacement(oldText: "repeat", newText: "replacement")], to: "repeat repeat"
                )
            }, "2 occurrences"),
            (try capturedError {
                try JSONFileOperations.validate(Data("{".utf8), path: "notes/demo.json")
            }, "not valid JSON"),
            (try capturedError {
                try FileResourcePolicy.validate(
                    bytes: 11, format: .markdown, path: marker, maximumBytes: 10
                )
            }, "limit 10"),
        ]
        for (error, expectedDetail) in failures {
            let result = try await readResult(throwing: error)
            let message = text(result)
            #expect(result.isError == true)
            #expect(message.contains(expectedDetail))
            #expect(!message.contains("internal error"))
            #expect(!message.contains(marker))
            #expect(message.utf8.count <= 1_024)
        }
    }

    @Test("Canvas validation categories are actionable without exposing stored identifiers")
    func canvasFailuresDoNotEchoIdentifiers() async throws {
        let identifier = marker + String(repeating: "x", count: 8_192)
        let node: [String: Any] = [
            "id": identifier, "type": "text", "x": 0, "y": 0,
            "width": 100, "height": 100, "text": "ordinary",
        ]
        var malformedNode = node
        malformedNode["type"] = identifier
        let fixtures: [([String: Any], String)] = [
            (["nodes": [node, node], "edges": []], "Duplicate node"),
            (["nodes": [node], "edges": [[
                "id": identifier, "fromNode": identifier, "toNode": identifier + "-missing",
            ]]], "missing node"),
            (["nodes": [malformedNode], "edges": []], "Invalid canvas JSON"),
        ]
        for (fixture, expectedDetail) in fixtures {
            let bytes = try JSONSerialization.data(withJSONObject: fixture)
            let error = try capturedError { try CanvasDocumentValidator.validate(jsonData: bytes) }
            let result = try await readResult(throwing: error)
            let message = text(result)
            #expect(result.isError == true)
            #expect(message.contains(expectedDetail))
            #expect(!message.contains("internal error"))
            #expect(!message.contains(marker))
            #expect(message.utf8.count <= 1_024)
        }
    }

    @Test("Routing errors omit arbitrary path values while preserving the corrective rule")
    func routingErrorsDoNotEchoPaths() async throws {
        for path in ["notes/" + marker + String(repeating: "x", count: 8_192) + ".csv",
                     marker + "/demo.md"] {
            let error = try capturedError {
                _ = try ReadableFileTarget.resolve(
                    path: path, format: .markdown, vaultPath: "/unused-test-root"
                )
            }
            let result = try await readResult(throwing: error)
            let message = text(result)
            #expect(result.isError == true)
            #expect(message.contains(path.hasPrefix("notes/") ? "extension" : "notes/ or references/"))
            #expect(!message.contains(marker))
            #expect(message.utf8.count <= 1_024)
        }
    }

    @Test("Listing unknown fields are rejected without returning their names")
    func listingUnknownFieldsDoNotEcho() async throws {
        let listing = ListingSpy()
        let result = try await ListFilesToolController(listing: listing).call(.init(
            name: "list_files",
            arguments: ["area": .string("notes"),
                        marker + String(repeating: "x", count: 8_192): .bool(true)]
        ))
        let message = text(result)
        #expect(result.isError == true)
        #expect(message.lowercased().contains("unknown parameter"))
        #expect(message.utf8.count <= 1_024)
        #expect(!message.contains(marker))
        #expect(await listing.calls == 0)
    }

    @Test("Every final error mapper enforces the response byte budget without partial identifiers")
    func finalErrorResponseIsBounded() {
        let unbounded = marker + String(repeating: "x", count: 8_192)
        for result in [FileToolResultMapper.failure(unbounded), SearchToolResultMapper.failure(unbounded)] {
            let message = text(result)
            #expect(result.isError == true)
            #expect(!message.isEmpty)
            #expect(message.utf8.count <= 1_024)
            #expect(!message.contains(marker))
        }
    }

    @Test("Every audited PDF failure gives bounded corrective guidance without arbitrary detail")
    func pdfFailuresRemainActionable() async throws {
        let privateDetail = "/private/" + marker + String(repeating: "x", count: 8_192)
        let failures: [(PDFReadError, [String])] = [
            (.cannotOpenPDF(privateDetail), ["Cannot open PDF", "check"]),
            (.invalidSelection(privateDetail), ["Invalid PDF page selection", "pages", "page_range"]),
            (.pageOutOfBounds(page: 7, totalPages: 3), ["page 7", "1...3"]),
            (.pageOutOfBounds(page: 1, totalPages: 0), ["no pages", "check"]),
            (.cannotRenderPage(2), ["render PDF page 2", "another page"]),
            (.responseTooLarge(maximumBytes: 65_536), ["65536", "fewer pages"]),
            (.busy, ["busy", "retry", "finishes"]),
        ]
        for (error, expectedDetails) in failures {
            let result = try await readResult(throwing: error)
            let message = text(result)
            #expect(result.isError == true)
            for detail in expectedDetails { #expect(message.contains(detail)) }
            #expect(!message.contains("internal error"))
            #expect(!message.contains(marker))
            #expect(!message.contains("/private/"))
            #expect(!message.contains("1...0"))
            #expect(message.utf8.count <= 1_024)
        }
    }

    @Test("A real out-of-range PDF read reports the document's usable page range")
    func realPDFPageRangeIsActionable() async throws {
        let fixture = try PDFAdmissionFixture.make()
        defer { fixture.cleanup() }
        let result = try await FileToolController(readOnly: true, files: fixture.service).call(.init(
            name: "read_file",
            arguments: ["format": .string("pdf"), "path": .string("references/0.pdf"),
                        "pages": .array([.int(2)])]
        ))
        let message = text(result)
        #expect(result.isError == true)
        #expect(message.contains("page 2"))
        #expect(message.contains("1...1"))
        #expect(!message.contains("internal error"))
        #expect(!message.contains(fixture.parent.path))
        #expect(message.utf8.count <= 1_024)
    }

    @Test("Real vault queue exhaustion remains retryable through file, listing, and move tools")
    func capacityFailuresRemainActionableAcrossTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPErrorCapacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = VaultAccessCoordinator(
            lockURL: root.appendingPathComponent("vault.lock"), maximumWaiters: 0
        )
        let hold = PDFSnapshotAdmissionHold()
        let blocker = Task { try await coordinator.withMutation { await hold.wait() } }
        await hold.waitUntilEntered()
        let error: any Error
        do {
            try await coordinator.withRead {}
            error = FixtureError.expectedFailure
        } catch let failure { error = failure }
        await hold.release()
        try await blocker.value
        #expect(error is VaultAccessCoordinator.CapacityExceeded)
        for result in try await [
            readResult(throwing: error), listingResult(throwing: error), pathResult(throwing: error),
        ] {
            let message = text(result)
            #expect(result.isError == true)
            #expect(message.contains("at capacity"))
            #expect(message.contains("retry after"))
            #expect(message.contains("finishes"))
            #expect(!message.contains("internal error"))
            #expect(message.utf8.count <= 1_024)
        }
    }

    @Test("PDF admission exhaustion stays actionable through the search tool")
    func searchPDFCapacityRemainsActionable() async throws {
        let admission = PDFReadAdmission(maximumQueuedRequests: 0)
        let hold = PDFSnapshotAdmissionHold()
        let blocker = Task { try await admission.withPermit { await hold.wait() } }
        await hold.waitUntilEntered()
        let error: any Error
        do {
            try await admission.withPermit {}
            error = FixtureError.expectedFailure
        } catch let failure { error = failure }
        await hold.release()
        try await blocker.value
        guard case PDFReadError.busy = error else {
            Issue.record("Expected actual PDF admission capacity failure")
            return
        }

        let result = try await searchResult(throwing: error)
        let message = text(result)
        #expect(result.isError == true)
        #expect(message.contains("busy"))
        #expect(message.contains("retry"))
        #expect(message.contains("finishes"))
        #expect(!message.contains("Unexpected vault read error"))
        #expect(message.utf8.count <= 1_024)
    }

    @Test("Unknown Cocoa and descriptive errors remain opaque in every audited controller")
    func unknownErrorsStayOpaqueAcrossTools() async throws {
        let detail = "/private/" + marker + String(repeating: "x", count: 8_192)
        let failures: [any Error] = [
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: detail, NSFilePathErrorKey: detail]),
            DescriptiveFailure(detail: detail),
        ]
        for error in failures {
            for result in try await [
                readResult(throwing: error), listingResult(throwing: error), pathResult(throwing: error),
            ] {
                let message = text(result)
                #expect(result.isError == true)
                #expect(!message.isEmpty)
                #expect(!message.contains(marker))
                #expect(!message.contains("/private/"))
                #expect(message.utf8.count <= 1_024)
            }
        }
    }

    @Test("Foundation POSIX errors never expose injected localized details through search")
    func posixErrorsRemainOpaqueInSearch() async throws {
        // The short case is below the final byte cap, so that cap cannot mask a leak.
        for detail in ["/private/" + marker,
                       "/private/" + marker + String(repeating: "x", count: 8_192)] {
            let error = POSIXError(.EACCES, userInfo: [
                NSLocalizedDescriptionKey: detail, NSFilePathErrorKey: detail,
            ])
            let result = try await searchResult(throwing: error)
            let message = text(result)
            #expect(result.isError == true)
            #expect(message.contains("Unexpected vault read error"))
            #expect(!message.contains(marker))
            #expect(!message.contains("/private/"))
            #expect(message.utf8.count <= 1_024)
            for control in try await [
                readResult(throwing: error), listingResult(throwing: error), pathResult(throwing: error),
            ] {
                #expect(control.isError == true)
                #expect(!text(control).contains(marker))
                #expect(text(control).utf8.count <= 1_024)
            }
        }
    }

    private func searchResult(throwing error: any Error) async throws -> CallTool.Result {
        try await SearchToolController(search: FailingSearch(error: error)).call(.init(
            name: "search_vault",
            arguments: ["location": .string("notes"), "query": .string("ordinary")]
        ))
    }

    private struct FailingSearch: VaultSearchService {
        let searchableFormats: [FileFormat] = []
        let error: any Error
        func search(_ request: VaultSearchRequest) async throws -> VaultSearchResponse { throw error }
    }

    private func listingResult(throwing error: any Error) async throws -> CallTool.Result {
        try await ListFilesToolController(listing: FailingListing(error: error)).call(.init(
            name: "list_files", arguments: ["area": .string("notes")]
        ))
    }

    private func pathResult(throwing error: any Error) async throws -> CallTool.Result {
        try await PathMoveToolController(readOnly: false, paths: FailingPaths(error: error)).call(.init(
            name: "move_path",
            arguments: ["kind": .string("directory"), "source_path": .string("notes/source"),
                        "destination_path": .string("notes/destination")]
        ))
    }

    private struct DescriptiveFailure: Error, CustomStringConvertible {
        let detail: String
        var description: String { detail }
    }

    private struct FailingListing: FileListingService {
        let error: any Error
        func list(_ request: ListFilesRequest) async throws -> ListFilesResult { throw error }
    }

    private struct FailingPaths: PathMoveService {
        let error: any Error
        func move(_ request: MovePathRequest) async throws -> FileOperationOutput { throw error }
    }

    private func capturedError(_ operation: () throws -> Void) throws -> any Error {
        do { try operation() } catch { return error }
        throw FixtureError.expectedFailure
    }

    private func readResult(throwing error: any Error) async throws -> CallTool.Result {
        try await FileToolController(readOnly: false, files: FailingService(error: error)).call(.init(
            name: "read_file",
            arguments: ["format": .string("markdown"), "path": .string("notes/demo.md")]
        ))
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined()
    }

    private enum FixtureError: Error { case expectedFailure }

    private struct FailingService: FileCRUDService {
        let error: any Error
        func create(_ request: CreateFileRequest) async throws -> FileOperationOutput { throw error }
        func read(_ request: ReadFileRequest) async throws -> FileOperationOutput { throw error }
        func update(_ request: UpdateFileRequest) async throws -> FileOperationOutput { throw error }
        func delete(_ request: DeleteFileRequest) async throws -> FileOperationOutput { throw error }
    }

    private actor ListingSpy: FileListingService {
        private(set) var calls = 0
        func list(_ request: ListFilesRequest) async throws -> ListFilesResult {
            calls += 1
            return ListFilesResult(files: [], nextCursor: nil)
        }
    }
}
