import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("CSV file operations")
struct CSVFileOperationsTests {
    @Test("Quoted commas, escaped quotes, and embedded newlines are valid")
    func quotedFields() throws {
        let csv = "name,note,value\r\n"
            + "alice,\"hello, world\",1\r\n"
            + "bob,\"line 1\r\nline 2 and \"\"quoted\"\"\",2\r\n"

        #expect(try CSVDocumentInspector.inspect(csv) == CSVInspection(
            rowCount: 3,
            columnCount: 3
        ))
    }

    @Test("Malformed quoting and inconsistent rows are rejected")
    func malformedCSV() {
        #expect(throws: CSVDocumentInspector.ValidationError.self) {
            try CSVDocumentInspector.inspect("a,b\nvalue,un\"quoted")
        }
        #expect(throws: CSVDocumentInspector.ValidationError.self) {
            try CSVDocumentInspector.inspect("a,b\n1,2,3")
        }
        #expect(throws: CSVDocumentInspector.ValidationError.self) {
            try CSVDocumentInspector.inspect("a,b\n1,\"unfinished")
        }
    }

    @Test("Creation and reading preserve CSV bytes")
    func losslessCreateAndRead() throws {
        let target = try makeTarget()
        let source = "id,value\r\n1,alpha\r\n"
        let operations = CSVFileOperations()
        let prepared = try operations.prepareCreate(
            TextFileCreateInput(data: Data(source.utf8), tags: []),
            target: target
        )
        #expect(prepared.data == Data(source.utf8))

        let output = try operations.read(
            ReadFileRequest(
                format: .csv,
                path: target.relativePath,
                options: .default
            ),
            target: target.readable,
            snapshot: FileSnapshot(data: prepared.data, modifiedDate: nil)
        )
        guard case .text(let returned) = output.contents.first else {
            Issue.record("Expected raw CSV text")
            return
        }
        #expect(returned == source)
    }

    @Test("CSV replace, append, and exact patches validate the final table")
    func updateModes() throws {
        let target = try makeTarget()
        let operations = CSVFileOperations()
        let original = Data("id,value\n1,alpha".utf8)
        let snapshot = FileSnapshot(data: original, modifiedDate: nil)

        let appended = try operations.prepareUpdate(
            update(target: target, snapshot: snapshot, mode: .append, content: "2,beta"),
            target: target,
            snapshot: snapshot
        )
        #expect(try TextFileSupport.string(from: appended.data) ==
            "id,value\n1,alpha\n2,beta")

        let patched = try operations.prepareUpdate(
            update(
                target: target,
                snapshot: snapshot,
                mode: .patch,
                replacements: [
                    TextReplacement(oldText: "alpha", newText: "updated"),
                ]
            ),
            target: target,
            snapshot: snapshot
        )
        #expect(try TextFileSupport.string(from: patched.data) ==
            "id,value\n1,updated")

        let replaced = try operations.prepareUpdate(
            update(target: target, snapshot: snapshot, mode: .replace, content: "x,y\n3,4"),
            target: target,
            snapshot: snapshot
        )
        #expect(try TextFileSupport.string(from: replaced.data) == "x,y\n3,4")

        #expect(throws: CSVDocumentInspector.ValidationError.self) {
            try operations.prepareUpdate(
                update(target: target, snapshot: snapshot, mode: .append, content: "too,many,fields"),
                target: target,
                snapshot: snapshot
            )
        }
    }

    @Test("CSV append uses only CR or LF as a record boundary")
    func appendRecordBoundary() throws {
        let target = try makeTarget()
        let existing = "a,b\u{2028}"
        let snapshot = FileSnapshot(
            data: Data(existing.utf8),
            modifiedDate: nil
        )
        let prepared = try CSVFileOperations().prepareUpdate(
            update(
                target: target,
                snapshot: snapshot,
                mode: .append,
                content: "1,2"
            ),
            target: target,
            snapshot: snapshot
        )
        #expect(try TextFileSupport.string(from: prepared.data) ==
            existing + "\n1,2")
        #expect(try CSVDocumentInspector.inspect(
            TextFileSupport.string(from: prepared.data)
        ).rowCount == 2)
    }

    @Test("Leading UTF-8 BOM survives CSV reads and patches")
    func byteOrderMarkIsPreserved() throws {
        let target = try makeTarget()
        let operations = CSVFileOperations()
        let original = Data([0xef, 0xbb, 0xbf])
            + Data("\"name\",value\nalpha,1".utf8)
        let prepared = try operations.prepareCreate(
            TextFileCreateInput(data: original, tags: []),
            target: target
        )
        let snapshot = FileSnapshot(data: prepared.data, modifiedDate: nil)
        let read = try operations.read(
            ReadFileRequest(
                format: .csv,
                path: target.relativePath,
                options: .default
            ),
            target: target.readable,
            snapshot: snapshot
        )
        guard case .text(let text) = read.contents.first else {
            Issue.record("Expected BOM-preserving CSV text")
            return
        }
        #expect(Data(text.utf8) == original)

        let patched = try operations.prepareUpdate(
            update(
                target: target,
                snapshot: snapshot,
                mode: .patch,
                replacements: [
                    TextReplacement(oldText: "alpha", newText: "beta"),
                ]
            ),
            target: target,
            snapshot: snapshot
        )
        #expect(patched.data.starts(with: [0xef, 0xbb, 0xbf]))
    }

    @Test("Oversized CSV updates fail before table inspection")
    func oversizedUpdate() throws {
        let target = try makeTarget()
        let snapshot = FileSnapshot(data: Data("a".utf8), modifiedDate: nil)
        let oversized = String(
            repeating: "a",
            count: FileFormat.csv.maximumFileBytes + 1
        )

        #expect(throws: FileResourcePolicy.Violation.self) {
            try CSVFileOperations().prepareUpdate(
                update(
                    target: target,
                    snapshot: snapshot,
                    mode: .replace,
                    content: oversized
                ),
                target: target,
                snapshot: snapshot
            )
        }
    }

    private func makeTarget() throws -> WritableFileTarget {
        let root = NSTemporaryDirectory()
            + "CSVFileOperationsTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return try WritableFileTarget.resolve(
            path: "notes/measurements.csv",
            format: .csv,
            vaultPath: root
        )
    }

    private func update(
        target: WritableFileTarget,
        snapshot: FileSnapshot,
        mode: FileUpdateMode,
        content: String? = nil,
        replacements: [TextReplacement] = []
    ) -> UpdateFileRequest {
        UpdateFileRequest(
            mutationID: MutationID(),
            expectedRevision: snapshot.revision,
            format: .csv,
            path: target.relativePath,
            content: content,
            mode: mode,
            replacements: replacements
        )
    }
}
