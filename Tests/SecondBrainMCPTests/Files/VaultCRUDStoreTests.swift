import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Generic files — CRUD store")
struct VaultCRUDStoreTests {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "VaultCRUDStoreTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes/deep", withIntermediateDirectories: true)
        return root
    }

    @Test("Create, snapshot, replace, and soft-delete share one persistence path")
    func lifecycle() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let target = try WritableFileTarget.resolve(path: "notes/deep/a.log", format: .log, vaultPath: root)

        try await store.create(target: target, data: Data("one".utf8))
        let snapshot = try await store.snapshot(target.readable)
        #expect(String(data: snapshot.data, encoding: .utf8) == "one")

        try await store.replace(target: target, data: Data("two".utf8), expected: snapshot)
        #expect(try String(contentsOf: target.url, encoding: .utf8) == "two")

        let trash = try await store.softDelete(target: target)
        #expect(trash.hasPrefix(".trash/"))
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
        #expect(FileManager.default.fileExists(atPath: root + "/" + trash))
    }

    @Test("Replace rejects a stale snapshot")
    func staleUpdate() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let target = try WritableFileTarget.resolve(path: "notes/deep/a.log", format: .log, vaultPath: root)
        try await store.create(target: target, data: Data("one".utf8))
        let snapshot = try await store.snapshot(target.readable)

        try Data("external edit".utf8).write(to: target.url, options: .atomic)
        await #expect(throws: VaultCRUDStore.StoreError.self) {
            try await store.replace(target: target, data: Data("ours".utf8), expected: snapshot)
        }
        #expect(try String(contentsOf: target.url, encoding: .utf8) == "external edit")
    }

    @Test("Create rejects an existing destination")
    func noClobber() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let target = try WritableFileTarget.resolve(path: "notes/a.har", format: .har, vaultPath: root)
        try await store.create(target: target, data: Data("first".utf8))
        await #expect(throws: VaultCRUDStore.StoreError.self) {
            try await store.create(target: target, data: Data("second".utf8))
        }
    }

    @Test("Snapshot and soft-delete share regular-file validation")
    func validatesReadableFileKind() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let missing = try WritableFileTarget.resolve(
            path: "notes/deep/missing.log",
            format: .log,
            vaultPath: root
        )

        await #expect(throws: VaultFileInspector.InspectionError.self) {
            _ = try await store.snapshot(missing.readable)
        }
        await #expect(throws: VaultFileInspector.InspectionError.self) {
            _ = try await store.softDelete(target: missing)
        }

        let directory = try WritableFileTarget.resolve(
            path: "notes/deep/directory.log",
            format: .log,
            vaultPath: root
        )
        try FileManager.default.createDirectory(
            at: directory.url,
            withIntermediateDirectories: true
        )
        await #expect(throws: VaultFileInspector.InspectionError.self) {
            _ = try await store.snapshot(directory.readable)
        }
        await #expect(throws: VaultFileInspector.InspectionError.self) {
            _ = try await store.softDelete(target: directory)
        }
        #expect(FileManager.default.fileExists(atPath: directory.url.path))
    }

    @Test("Create and replace reject files beyond the format policy")
    func rejectsOversizedWrites() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let target = try WritableFileTarget.resolve(
            path: "notes/deep/bounded.md",
            format: .markdown,
            vaultPath: root
        )
        let oversized = Data(count: FileFormat.markdown.maximumFileBytes + 1)

        await #expect(throws: FileResourcePolicy.Violation.self) {
            try await store.create(target: target, data: oversized)
        }
        #expect(!FileManager.default.fileExists(atPath: target.url.path))

        try await store.create(target: target, data: Data("original".utf8))
        let snapshot = try await store.snapshot(target.readable)
        await #expect(throws: FileResourcePolicy.Violation.self) {
            try await store.replace(
                target: target,
                data: oversized,
                expected: snapshot
            )
        }
        #expect(try String(contentsOf: target.url, encoding: .utf8) == "original")
    }

    @Test("Soft-delete paths cannot collide for equal basenames")
    func uniqueTrashPaths() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let first = try WritableFileTarget.resolve(path: "notes/a/same.log", format: .log, vaultPath: root)
        let second = try WritableFileTarget.resolve(path: "notes/b/same.log", format: .log, vaultPath: root)

        try await store.create(target: first, data: Data("one".utf8))
        try await store.create(target: second, data: Data("two".utf8))
        let firstTrash = try await store.softDelete(target: first)
        let secondTrash = try await store.softDelete(target: second)

        #expect(firstTrash != secondTrash)
        #expect(FileManager.default.fileExists(atPath: root + "/" + firstTrash))
        #expect(FileManager.default.fileExists(atPath: root + "/" + secondTrash))
    }

    @Test("Soft delete rejects a symlinked trash directory")
    func softDeleteDoesNotEscapeThroughTrashSymlink() async throws {
        let root = try makeVault()
        let store = VaultCRUDStore(vaultPath: root)
        let target = try WritableFileTarget.resolve(
            path: "notes/deep/a.log",
            format: .log,
            vaultPath: root
        )
        try await store.create(target: target, data: Data("keep".utf8))

        let external = URL(fileURLWithPath: root)
            .deletingLastPathComponent()
            .appendingPathComponent("external-trash-(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: root).appendingPathComponent(".trash"),
            withDestinationURL: external
        )

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            _ = try await store.softDelete(target: target)
        }
        #expect(FileManager.default.fileExists(atPath: target.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test("Create revalidates a parent replaced by an outside symlink")
    func createRejectsChangedParentPath() async throws {
        let root = try makeVault()
        let safeDirectory = URL(fileURLWithPath: root + "/notes/safe")
        try FileManager.default.createDirectory(
            at: safeDirectory,
            withIntermediateDirectories: true
        )
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/note.log",
            format: .log,
            vaultPath: root
        )
        try FileManager.default.removeItem(at: safeDirectory)

        let external = URL(fileURLWithPath: root)
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: safeDirectory,
            withDestinationURL: external
        )

        await #expect(throws: PathValidationError.self) {
            try await VaultCRUDStore(vaultPath: root).create(
                target: target,
                data: Data("blocked".utf8)
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: external.appendingPathComponent("note.log").path
        ))
    }
}
