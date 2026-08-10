import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `CSV format semantics` {
    @Test
    func `Creation validates CSV and preserves exact bytes`() throws {
        let target = try makeTarget()
        let original = Data(
            [0xEF, 0xBB, 0xBF]
                + Array("id,value\r\n1,\"alpha,beta\"".utf8)
        )
        let prepared = try CSVFileOperations().prepareCreate(
            TextFileCreateInput(data: original, tags: []),
            target: target
        )

        #expect(prepared.data == original)
        try CSVFileOperations.validate(prepared.data, path: target.relativePath)
    }

    @Test
    func `Invalid tables are rejected before persistence`() throws {
        let target = try makeTarget()
        for text in [
            "a,b\n1",
            "a,b\n\"unterminated",
        ] {
            #expect(throws: CSVDocumentInspector.ValidationError.self) {
                try CSVFileOperations().prepareCreate(
                    TextFileCreateInput(data: Data(text.utf8), tags: []),
                    target: target
                )
            }
        }
    }

    @Test
    func `CSV append uses only CR or LF record boundaries`() {
        #expect(
            CSVFileOperations.appendingRows("c,d", to: "a,b\r\n")
                == "a,b\r\nc,d"
        )
        #expect(
            CSVFileOperations.appendingRows("c,d", to: "a,b\r")
                == "a,b\rc,d"
        )
        #expect(
            CSVFileOperations.appendingRows("c,d", to: "a,b\n")
                == "a,b\nc,d"
        )
        #expect(
            CSVFileOperations.appendingRows("c,d", to: "a,b\u{2028}")
                == "a,b\u{2028}\nc,d"
        )
    }

    @Test
    func `CSV validation enforces the shared resource bound`() throws {
        let target = try makeTarget()
        let oversized = Data(
            repeating: 0x61,
            count: FileResourcePolicy.maximumBytes(for: .csv) + 1
        )
        #expect(throws: FileResourcePolicy.Violation.self) {
            try CSVFileOperations.validate(
                oversized,
                path: target.relativePath
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
            path: "notes/table.csv",
            format: .csv,
            vaultPath: root
        )
    }
}
