import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Generic files — structured format operations` {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "StructuredFileOperationsTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return root
    }

    private func input(_ content: String, tags: [String] = []) -> TextFileCreateInput {
        TextFileCreateInput(data: Data(content.utf8), tags: tags)
    }

    @Test
    func `HAR creation validates structure and reading returns atomic JSON`() async throws {
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
        guard case .text(let returned) = output.contents.first else {
            Issue.record("Expected HAR JSON")
            return
        }
        let returnedObject = try #require(
            JSONSerialization.jsonObject(with: Data(returned.utf8)) as? NSDictionary
        )
        let expectedObject = try #require(
            JSONSerialization.jsonObject(with: Data(content.utf8)) as? NSDictionary
        )
        #expect(returnedObject == expectedObject)
    }

    @Test
    func `Malformed HAR is rejected before persistence`() throws {
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

    @Test
    func `HAR creation stores sanitized bytes and reports the intervention`() throws {
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

    @Test
    func `Raw reads sanitize legacy HAR bytes and reject unknown secret locations`() throws {
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
            options: .default
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
            Issue.record("Expected sanitized HAR JSON")
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

    @Test
    func `HAR summaries reject credentials in projected legacy fields`() throws {
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

    @Test
    func `Patch failures never echo caller-supplied search text`() {
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

    @Test
    func `Opaque text formats cannot import arbitrary external paths`() async throws {
        let root = try makeVault()
        let source = NSTemporaryDirectory() + "external-secret-\(UUID().uuidString).log"
        try Data("private".utf8).write(to: URL(fileURLWithPath: source))
        let operations = LogFileOperations()
        let family = StoredTextFileOperationFamily(
            delete: DeleteOperationBinding(
                allowedAreas: [.notes],
                execute: { _, _ in }
            )
        )
        let definition = family.definition(
            format: .log,
            create: operations.prepareCreate,
            read: operations.read,
            updateModes: [.append]
        )
        let create = try #require(definition.operations.create)
        let target = try WritableFileTarget.resolve(path: "notes/import.log", format: .log, vaultPath: root)
        let request = CreateFileRequest(

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

    @Test
    func `Patch creation validates and summarizes a unified diff`() throws {
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

    @Test
    func `Log reads a bounded tail`() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let operations = LogFileOperations()
        let target = try WritableFileTarget.resolve(path: "notes/app.log", format: .log, vaultPath: root)
        let prepared = try operations.prepareCreate(
            input("one\ntwo\nthree"),
            target: target
        )
        try await store.create(target: target, data: prepared.data)

        let options = ReadFileOptions(tailLines: 2)
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
    }

    @Test
    func `A canceled log read stops before scanning its snapshot`() async throws {
        let root = try makeVault()
        let operations = LogFileOperations()
        let target = try WritableFileTarget.resolve(
            path: "notes/app.log",
            format: .log,
            vaultPath: root
        ).readable
        let snapshot = FileSnapshot(
            data: Data(String(repeating: "line\n", count: 100).utf8),
            modifiedDate: nil
        )

        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try operations.read(
                ReadFileRequest(
                    format: .log,
                    path: target.relativePath,
                    options: .default
                ),
                target: target,
                snapshot: snapshot
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `Log reads safely clamp extreme caller-controlled line values`() throws {
        let root = try makeVault()
        let operations = LogFileOperations()
        let target = try WritableFileTarget.resolve(
            path: "notes/app.log",
            format: .log,
            vaultPath: root
        ).readable
        let snapshot = FileSnapshot(data: Data("one\ntwo\nthree".utf8), modifiedDate: nil)
        let options = ReadFileOptions(
            startLine: .min,
            maxLines: .max
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

    @Test
    func `Newline-dense logs retain only the requested window`() throws {
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

        let options = ReadFileOptions(tailLines: 2)
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

    @Test
    func `CRLF is one logical line delimiter`() {
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

    @Test
    func `Deleted and metadata-only patches report their affected file`() throws {
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

    @Test
    func `Patch filenames containing spaces count one structural file`() throws {
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

    @Test
    func `Malformed Git patch headers are rejected`() throws {
        #expect(throws: PatchFileOperations.PatchError.self) {
            try PatchFileOperations.inspect(
                data: Data("diff --git nope\n+not a hunk".utf8),
                path: "notes/bad.patch"
            )
        }
    }
}
