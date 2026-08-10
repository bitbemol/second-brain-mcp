import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Generic files — structured format operations")
struct StructuredFileOperationsTests {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "StructuredFileOperationsTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return root
    }

    private func input(_ content: String, tags: [String] = []) -> TextFileCreateInput {
        TextFileCreateInput(data: Data(content.utf8), tags: tags)
    }

    @Test("HAR creation validates structure and reading summarizes entries")
    func har() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let operations = HARFileOperations()
        let target = try WritableFileTarget.resolve(path: "notes/login.har", format: .har, vaultPath: root)
        let content = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[
          {"request":{"method":"GET","url":"https://example.com/a"},"response":{"status":200},"time":12.5},
          {"request":{"method":"POST","url":"https://api.example.com/b"},"response":{"status":500},"time":20}
        ]}}
        """
        let prepared = try operations.prepareCreate(
            input(content),
            target: target
        )
        try await store.create(target: target, data: prepared.data)

        let snapshot = try await store.snapshot(target.readable)
        let output = try operations.read(
            ReadFileRequest(format: .har, path: target.relativePath, options: .default),
            target: target.readable,
            snapshot: snapshot
        )
        guard case .text(let summary) = output.contents.first else {
            Issue.record("Expected HAR summary text")
            return
        }
        #expect(summary.contains("Entries: 2"))
        #expect(summary.contains("GET=1"))
        #expect(summary.contains("500=1"))
        #expect(!summary.contains("\"entries\""))
    }

    @Test("Malformed HAR is rejected before persistence")
    func invalidHAR() throws {
        let root = try makeVault()
        let operations = HARFileOperations()
        let target = try WritableFileTarget.resolve(path: "notes/bad.har", format: .har, vaultPath: root)
        #expect(throws: HARInspector.InspectionError.self) {
            try operations.prepareCreate(
                input("{}"),
                target: target
            )
        }
        #expect(!FileManager.default.fileExists(atPath: target.url.path))

        #expect(throws: HARInspector.InspectionError.self) {
            try operations.prepareCreate(
                input(#"{"log":{"version":"1.2","creator":{"name":"Test"},"entries":[{}]}}"#),
                target: target
            )
        }
    }

    @Test("HAR creation stores sanitized bytes and reports the intervention")
    func sanitizedHAR() throws {
        let root = try makeVault()
        let operations = HARFileOperations()
        let target = try WritableFileTarget.resolve(
            path: "notes/sensitive.har",
            format: .har,
            vaultPath: root
        )
        let secret = "Bearer " + String(repeating: "s", count: 32)
        let content = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[
          {"request":{"method":"GET","url":"https://example.com",
           "headers":[{"name":"Authorization","value":"\(secret)"}]},
           "response":{"status":200},"time":1}
        ]}}
        """

        let prepared = try operations.prepareCreate(
            input(content),
            target: target
        )
        let stored = try #require(String(data: prepared.data, encoding: .utf8))
        guard case .text(let output) = prepared.output.contents.first else {
            Issue.record("Expected HAR creation summary")
            return
        }

        #expect(!stored.contains(secret))
        #expect(stored.contains(HARSensitiveDataSanitizer.redactionMarker))
        #expect(output.contains("Sanitized 1 sensitive value"))
    }

    @Test("Raw reads sanitize legacy HAR bytes and reject unknown secret locations")
    func legacyHARRawRead() throws {
        let root = try makeVault()
        let operations = HARFileOperations()
        let target = try WritableFileTarget.resolve(
            path: "notes/legacy.har",
            format: .har,
            vaultPath: root
        )
        let secret = "Bearer " + String(repeating: "l", count: 32)
        let knownField = """
        {"log":{"version":"1.2","creator":{"name":"Test"},"entries":[
          {"request":{"method":"GET","url":"https://example.com",
           "headers":[{"name":"Authorization","value":"\(secret)"}]},
           "response":{"status":200},"time":1}
        ]}}
        """
        let rawRequest = ReadFileRequest(
            format: .har,
            path: target.relativePath,
            options: ReadFileOptions(
                raw: true,
                tailLines: nil,
                startLine: nil,
                maxLines: nil,
                page: nil,
                bookPage: nil,
                pageRange: nil,
                query: nil,
                maxPages: nil
            )
        )
        let output = try operations.read(
            rawRequest,
            target: target.readable,
            snapshot: FileSnapshot(
                data: Data(knownField.utf8),
                modifiedDate: nil
            )
        )
        guard case .text(let raw) = output.contents.first else {
            Issue.record("Expected sanitized raw HAR")
            return
        }
        #expect(!raw.contains(secret))
        #expect(raw.contains(HARSensitiveDataSanitizer.redactionMarker))

        let unknownField = knownField.replacingOccurrences(
            of: "\"response\":{\"status\":200}",
            with: "\"response\":{\"status\":200,\"content\":{\"text\":\"\(secret)\"}}"
        )
        #expect(throws: SensitiveContentPolicy.Violation.self) {
            try operations.read(
                rawRequest,
                target: target.readable,
                snapshot: FileSnapshot(
                    data: Data(unknownField.utf8),
                    modifiedDate: nil
                )
            )
        }
    }

    @Test("HAR summaries reject credentials in projected legacy fields")
    func legacyHARSummaryDoesNotDiscloseSecrets() throws {
        let root = try makeVault()
        let operations = HARFileOperations()
        let target = try WritableFileTarget.resolve(
            path: "notes/legacy-summary.har",
            format: .har,
            vaultPath: root
        )
        let secret = "Bearer " + String(repeating: "v", count: 32)
        let archive = """
        {"log":{"version":"1.2","creator":{"name":"\(secret)"},"entries":[
          {"request":{"method":"GET","url":"https://example.com"},
           "response":{"status":200},"time":1}
        ]}}
        """

        #expect(throws: SensitiveContentPolicy.Violation.self) {
            try operations.read(
                ReadFileRequest(
                    format: .har,
                    path: target.relativePath,
                    options: .default
                ),
                target: target.readable,
                snapshot: FileSnapshot(
                    data: Data(archive.utf8),
                    modifiedDate: nil
                )
            )
        }
    }

    @Test("Patch failures never echo caller-supplied search text")
    func patchFailureDoesNotEchoSearchText() {
        let secret = "Bearer " + String(repeating: "p", count: 32)
        do {
            _ = try TextFileSupport.apply(
                [TextReplacement(oldText: secret, newText: "removed")],
                to: "safe document"
            )
            Issue.record("Expected patch failure")
        } catch {
            #expect(!String(describing: error).contains(secret))
        }
    }

    @Test("Opaque text formats cannot import arbitrary external paths")
    func rejectsExternalTextSource() async throws {
        let root = try makeVault()
        let source = NSTemporaryDirectory() + "external-secret-\(UUID().uuidString).log"
        try Data("private".utf8).write(to: URL(fileURLWithPath: source))
        let operations = LogFileOperations()
        let family = StoredTextFileOperationFamily(
            store: VaultCRUDStore(vaultPath: root),
            delete: DeleteOperationBinding(
                id: .softDelete,
                allowedAreas: [.notes],
                execute: { _, _ in }
            )
        )
        let definition = family.definition(
            format: .log,
            handler: .log,
            create: operations.prepareCreate,
            read: operations.read,
            update: operations.prepareUpdate
        )
        let create = try #require(definition.operations.create)
        let target = try WritableFileTarget.resolve(path: "notes/import.log", format: .log, vaultPath: root)
        let request = CreateFileRequest(
            mutationID: MutationID(),
            format: .log,
            path: target.relativePath,
            content: nil,
            source: source,
            tags: [],
            transform: nil
        )

        await #expect(throws: TextFileIngress.IngressError.self) {
            try await create.execute(request, target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
    }

    @Test("Patch creation validates and summarizes a unified diff")
    func patch() throws {
        let root = try makeVault()
        let operations = PatchFileOperations()
        let target = try WritableFileTarget.resolve(path: "notes/fix.patch", format: .patch, vaultPath: root)
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let prepared = try operations.prepareCreate(
            input(diff),
            target: target
        )
        guard case .text(let summary) = prepared.output.contents.first else {
            Issue.record("Expected patch summary")
            return
        }
        #expect(summary.contains("Files: 1"))
        #expect(summary.contains("Hunks: 1"))
        #expect(summary.contains("+1 / -1"))
    }

    @Test("Log reads tail and only permits append updates")
    func log() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let operations = LogFileOperations()
        let target = try WritableFileTarget.resolve(path: "notes/app.log", format: .log, vaultPath: root)
        let prepared = try operations.prepareCreate(
            input("one\ntwo\nthree"),
            target: target
        )
        try await store.create(target: target, data: prepared.data)

        let options = ReadFileOptions(raw: false, tailLines: 2, startLine: nil, maxLines: nil, page: nil, bookPage: nil, pageRange: nil, query: nil, maxPages: nil)
        let readSnapshot = try await store.snapshot(target.readable)
        let output = try operations.read(
            ReadFileRequest(format: .log, path: target.relativePath, options: options),
            target: target.readable,
            snapshot: readSnapshot
        )
        guard case .text(let text) = output.contents.first else {
            Issue.record("Expected log text")
            return
        }
        #expect(!text.contains("\none\n"))
        #expect(text.contains("two\nthree"))

        let snapshot = try await store.snapshot(target.readable)
        let update = UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: snapshot.revision,
            format: .log,
            path: target.relativePath,
            content: "four",
            mode: .append,
            replacements: []
        )
        let updated = try operations.prepareUpdate(update, target: target, snapshot: snapshot)
        #expect(try TextFileSupport.string(from: updated.data).hasSuffix("three\nfour"))
    }

    @Test("Text handlers append to empty files without a leading blank line")
    func appendsToEmptyTextFiles() throws {
        let root = try makeVault()
        let snapshot = FileSnapshot(data: Data(), modifiedDate: nil)

        let markdownTarget = try WritableFileTarget.resolve(
            path: "notes/empty.md",
            format: .markdown,
            vaultPath: root
        )
        let markdownRequest = UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: snapshot.revision,
            format: .markdown,
            path: markdownTarget.relativePath,
            content: "first",
            mode: .append,
            replacements: []
        )
        let markdown = try MarkdownFileOperations().prepareUpdate(
            markdownRequest,
            target: markdownTarget,
            snapshot: snapshot
        )

        let logTarget = try WritableFileTarget.resolve(
            path: "notes/empty.log",
            format: .log,
            vaultPath: root
        )
        let logRequest = UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: snapshot.revision,
            format: .log,
            path: logTarget.relativePath,
            content: "first",
            mode: .append,
            replacements: []
        )
        let log = try LogFileOperations().prepareUpdate(
            logRequest,
            target: logTarget,
            snapshot: snapshot
        )

        #expect(try TextFileSupport.string(from: markdown.data) == "first")
        #expect(try TextFileSupport.string(from: log.data) == "first")
    }

    @Test("Log reads safely clamp extreme caller-controlled line values")
    func logExtremeLineWindow() throws {
        let root = try makeVault()
        let operations = LogFileOperations()
        let target = try WritableFileTarget.resolve(
            path: "notes/app.log",
            format: .log,
            vaultPath: root
        ).readable
        let snapshot = FileSnapshot(data: Data("one\ntwo\nthree".utf8), modifiedDate: nil)
        let options = ReadFileOptions(
            raw: false,
            tailLines: nil,
            startLine: .min,
            maxLines: .max,
            page: nil,
            bookPage: nil,
            pageRange: nil,
            query: nil,
            maxPages: nil
        )

        let output = try operations.read(
            ReadFileRequest(format: .log, path: target.relativePath, options: options),
            target: target,
            snapshot: snapshot
        )
        guard case .text(let text) = output.contents.first else {
            Issue.record("Expected log text")
            return
        }
        #expect(text.contains("lines 1-3 of 3"))
        #expect(text.hasSuffix("one\ntwo\nthree"))
    }

    @Test("Newline-dense logs retain only the requested window")
    func newlineDenseLogIsBounded() throws {
        let root = try makeVault()
        let operations = LogFileOperations()
        let target = try WritableFileTarget.resolve(
            path: "notes/dense.log",
            format: .log,
            vaultPath: root
        )
        let text = "first\n" + String(repeating: "\n", count: 250_000) + "last"
        let prepared = try operations.prepareCreate(input(text), target: target)
        guard case .text(let createSummary) = prepared.output.contents.first else {
            Issue.record("Expected log creation summary")
            return
        }
        #expect(createSummary.contains("250002 lines"))

        let options = ReadFileOptions(
            raw: false,
            tailLines: 2,
            startLine: nil,
            maxLines: nil,
            page: nil,
            bookPage: nil,
            pageRange: nil,
            query: nil,
            maxPages: nil
        )
        let output = try operations.read(
            ReadFileRequest(
                format: .log,
                path: target.relativePath,
                options: options
            ),
            target: target.readable,
            snapshot: FileSnapshot(data: prepared.data, modifiedDate: nil)
        )
        guard case .text(let rendered) = output.contents.first else {
            Issue.record("Expected bounded log text")
            return
        }
        #expect(rendered.contains("last 2 of 250002 lines"))
        #expect(rendered.hasSuffix("\nlast"))
        #expect(rendered.utf8.count < 1_024)
    }

    @Test("CRLF is one logical line delimiter")
    func crlfDoesNotCreateBlankLines() {
        let text = "one\r\ntwo\r\nthree"

        #expect(TextLineScanner.lineCount(in: text) == 3)
        #expect(
            TextLineScanner.window(
                in: text,
                startingAt: 1,
                maximumLines: 10
            ).lines == ["one", "two", "three"]
        )
    }

    @Test("Deleted and metadata-only patches report their affected file")
    func patchSummariesIncludeNonAdditionFiles() throws {
        let deletion = """
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -old
        """
        let modeChange = """
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755
        """

        let deletionSummary = try PatchFileOperations.inspect(
            data: Data(deletion.utf8),
            path: "notes/delete.patch"
        )
        let modeSummary = try PatchFileOperations.inspect(
            data: Data(modeChange.utf8),
            path: "notes/mode.patch"
        )

        #expect(deletionSummary.contains("Files: 1"))
        #expect(deletionSummary.contains("Hunks: 1"))
        #expect(modeSummary.contains("Files: 1"))
        #expect(modeSummary.contains("Hunks: 0"))
    }

    @Test("Patch filenames containing spaces count one structural file")
    func patchFilenameWithSpaces() throws {
        let diff = """
        diff --git a/old name.txt b/old name.txt
        --- a/old name.txt
        +++ b/old name.txt
        @@ -1 +1 @@
        -old
        +new
        """

        let summary = try PatchFileOperations.inspect(
            data: Data(diff.utf8),
            path: "notes/spaces.patch"
        )

        #expect(summary.contains("Files: 1"))
    }

    @Test("Malformed Git patch headers are rejected")
    func rejectsMalformedPatchHeader() throws {
        #expect(throws: PatchFileOperations.PatchError.self) {
            try PatchFileOperations.inspect(
                data: Data("diff --git nope\n+not a hunk".utf8),
                path: "notes/bad.patch"
            )
        }
    }

    @Test("Canvas reads validate content and flag missing file nodes")
    func canvasRead() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let operations = CanvasFileOperations(vaultPath: root)
        let target = try WritableFileTarget.resolve(path: "notes/board.canvas", format: .canvas, vaultPath: root)
        let canvas = #"{"nodes":[{"id":"file-1","type":"file","file":"notes/missing.png","x":0,"y":0,"width":100,"height":100}],"edges":[]}"#
        let prepared = try operations.prepareCreate(
            input(canvas),
            target: target
        )
        try await store.create(target: target, data: prepared.data)

        let snapshot = try await store.snapshot(target.readable)
        let output = try operations.read(
            ReadFileRequest(format: .canvas, path: target.relativePath, options: .default),
            target: target.readable,
            snapshot: snapshot
        )
        guard case .text(let text) = output.contents.first else {
            Issue.record("Expected canvas text")
            return
        }
        #expect(text.contains("⚠ file not found"))

        try Data("not json".utf8).write(to: target.url, options: .atomic)
        let invalidSnapshot = try await store.snapshot(target.readable)
        #expect(throws: CanvasDocumentValidator.ValidationError.self) {
            try operations.read(
                ReadFileRequest(format: .canvas, path: target.relativePath, options: .default),
                target: target.readable,
                snapshot: invalidSnapshot
            )
        }
    }
}
