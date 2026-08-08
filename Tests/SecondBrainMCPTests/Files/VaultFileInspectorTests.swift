import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault file inspection")
struct VaultFileInspectorTests {
    @Test("Returns regular-file metadata")
    func metadata() throws {
        let root = try makeVault()
        let target = try ReadableFileTarget.resolve(
            path: "notes/entry.log",
            format: .log,
            vaultPath: root
        )
        let data = Data("inspected".utf8)
        try data.write(to: target.url)

        let metadata = try VaultFileInspector.inspect(target)

        #expect(metadata.byteCount == data.count)
        #expect(metadata.modificationDate != nil)
    }

    @Test("Distinguishes missing and non-regular targets")
    func invalidEntries() throws {
        let root = try makeVault()
        let missing = try ReadableFileTarget.resolve(
            path: "notes/missing.log",
            format: .log,
            vaultPath: root
        )

        do {
            _ = try VaultFileInspector.inspect(missing)
            Issue.record("Expected missing target rejection")
        } catch VaultFileInspector.InspectionError.notFound(let path) {
            #expect(path == "notes/missing.log")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let directory = try ReadableFileTarget.resolve(
            path: "notes/directory.log",
            format: .log,
            vaultPath: root
        )
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)

        do {
            _ = try VaultFileInspector.inspect(directory)
            Issue.record("Expected non-regular target rejection")
        } catch VaultFileInspector.InspectionError.notARegularFile(let path) {
            #expect(path == "notes/directory.log")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Temporary snapshots remain immutable after the vault path changes")
    func temporarySnapshotIsPrivate() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = try ReadableFileTarget.resolve(
            path: "notes/evidence.log",
            format: .log,
            vaultPath: root
        )
        try Data("original".utf8).write(to: target.url)

        let snapshot = try VaultFileInspector.temporarySnapshot(
            target,
            maximumBytes: 64
        )
        defer { snapshot.remove() }
        try Data("replacement".utf8).write(to: target.url, options: .atomic)

        #expect(try Data(contentsOf: snapshot.url) == Data("original".utf8))
        #expect(snapshot.byteCount == 8)
    }

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "VaultFileInspectorTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
    }
}
