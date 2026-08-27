import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct VaultCRUDContainmentRaceTests {
    @Test
    func replacementCannotFollowParentSymlinkInstalledAfterSnapshot() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/a.log", format: .log, vaultPath: fixture.vault.path
        )
        let store = racingStore(fixture)

        await #expect(throws: (any Error).self) {
            _ = try await store.replace(
                target: target, data: Data("replacement".utf8),
                expectedRevision: FileSnapshot(data: Data("inside".utf8), modifiedDate: nil).revision
            )
        }

        #expect(try Data(contentsOf: fixture.outside.appendingPathComponent("a.log")) == Data("outside".utf8))
        #expect(try Data(contentsOf: fixture.retired.appendingPathComponent("a.log")) == Data("inside".utf8))
    }

    @Test
    func softDeleteCannotMoveOutsideFileAfterParentSymlinkRace() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/a.log", format: .log, vaultPath: fixture.vault.path
        )
        let store = racingStore(fixture)

        await #expect(throws: (any Error).self) {
            _ = try await store.softDelete(
                target: target,
                expectedRevision: FileSnapshot(data: Data("inside".utf8), modifiedDate: nil).revision
            )
        }

        #expect(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("a.log").path))
        if FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("a.log").path) {
            #expect(try Data(contentsOf: fixture.outside.appendingPathComponent("a.log")) == Data("outside".utf8))
        }
        #expect(try Data(contentsOf: fixture.retired.appendingPathComponent("a.log")) == Data("inside".utf8))
    }

    @Test
    func replacementRejectsFileSubstitutionAfterSnapshot() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/a.log", format: .log, vaultPath: fixture.vault.path
        )

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            _ = try await fileSubstitutionStore(fixture).replace(
                target: target, data: Data("replacement".utf8),
                expectedRevision: FileSnapshot(data: Data("inside".utf8), modifiedDate: nil).revision
            )
        }

        #expect(try Data(contentsOf: target.url) == Data("external replacement".utf8))
    }

    @Test
    func softDeleteRejectsFileSubstitutionAfterSnapshot() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/a.log", format: .log, vaultPath: fixture.vault.path
        )

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            _ = try await fileSubstitutionStore(fixture).softDelete(
                target: target,
                expectedRevision: FileSnapshot(data: Data("inside".utf8), modifiedDate: nil).revision
            )
        }

        #expect(FileManager.default.fileExists(atPath: target.url.path))
        if FileManager.default.fileExists(atPath: target.url.path) {
            #expect(try Data(contentsOf: target.url) == Data("external replacement".utf8))
        }
    }

    @Test
    func createRemainsOnPinnedParentAfterLateSymlinkSwap() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/new.log", format: .log, vaultPath: fixture.vault.path
        )
        let store = VaultCRUDStore(vaultPath: fixture.vault.path, beforePersistence: {
            try FileManager.default.moveItem(at: fixture.safe, to: fixture.retired)
            try FileManager.default.createSymbolicLink(at: fixture.safe, withDestinationURL: fixture.outside)
        })

        _ = try await store.create(target: target, data: Data("new note".utf8))

        #expect(!FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("new.log").path))
        #expect(try Data(contentsOf: fixture.retired.appendingPathComponent("new.log")) == Data("new note".utf8))
    }

    @Test
    func replacementRejectsLateFinalSymlinkWithoutTouchingItsTarget() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/a.log", format: .log, vaultPath: fixture.vault.path
        )
        let store = VaultCRUDStore(vaultPath: fixture.vault.path, beforePersistence: {
            try FileManager.default.moveItem(
                at: target.url, to: fixture.safe.appendingPathComponent("original.log")
            )
            try FileManager.default.createSymbolicLink(
                at: target.url, withDestinationURL: fixture.outside.appendingPathComponent("a.log")
            )
        })

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            _ = try await store.replace(
                target: target, data: Data("replacement".utf8),
                expectedRevision: FileSnapshot(data: Data("inside".utf8), modifiedDate: nil).revision
            )
        }

        #expect(try Data(contentsOf: fixture.outside.appendingPathComponent("a.log")) == Data("outside".utf8))
        #expect(try Data(contentsOf: fixture.safe.appendingPathComponent("original.log")) == Data("inside".utf8))
    }

    @Test
    func softDeleteUsesPinnedTrashAfterLateSymlinkSwap() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/a.log", format: .log, vaultPath: fixture.vault.path
        )
        let trash = fixture.vault.appendingPathComponent(".trash")
        let retiredTrash = fixture.vault.appendingPathComponent("retired-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let store = VaultCRUDStore(vaultPath: fixture.vault.path, beforePersistence: {
            try FileManager.default.moveItem(at: trash, to: retiredTrash)
            try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: fixture.outside)
        })

        let result = try await store.softDelete(
            target: target,
            expectedRevision: FileSnapshot(data: Data("inside".utf8), modifiedDate: nil).revision
        )

        let name = URL(fileURLWithPath: result.trashPath).lastPathComponent
        #expect(try Data(contentsOf: retiredTrash.appendingPathComponent(name)) == Data("inside".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent(name).path))
        #expect(try Data(contentsOf: fixture.outside.appendingPathComponent("a.log")) == Data("outside".utf8))
    }

    @Test
    func createNeverClobbersAConcurrentDestination() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/new.log", format: .log, vaultPath: fixture.vault.path
        )
        let store = VaultCRUDStore(vaultPath: fixture.vault.path, beforePersistence: {
            try Data("other creator".utf8).write(to: target.url)
        })

        await #expect(throws: VaultCRUDStore.StoreError.self) {
            _ = try await store.create(target: target, data: Data("our note".utf8))
        }

        #expect(try Data(contentsOf: target.url) == Data("other creator".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.safe.path)
            .allSatisfy { !$0.hasPrefix(".secondbrain-") })
    }

    @Test
    func failedCommitRemovesOnlyItsStagedTemporaryFile() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let target = try WritableFileTarget.resolve(
            path: "notes/safe/new.log", format: .log, vaultPath: fixture.vault.path
        )
        let store = VaultCRUDStore(vaultPath: fixture.vault.path, beforePersistence: {
            throw InjectedFailure.commit
        })

        await #expect(throws: InjectedFailure.self) {
            _ = try await store.create(target: target, data: Data("our note".utf8))
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.safe.path) == ["a.log"])
        #expect(try Data(contentsOf: fixture.safe.appendingPathComponent("a.log")) == Data("inside".utf8))
    }

    private enum InjectedFailure: Error { case commit }

    private func fileSubstitutionStore(_ fixture: Fixture) -> VaultCRUDStore {
        VaultCRUDStore(vaultPath: fixture.vault.path, snapshotLoader: { target, maximumBytes, protectedRoot, didReadBytes in
            let snapshot = try VaultFileInspector.snapshot(
                target, maximumBytes: maximumBytes, rejectHiddenDescendantsOf: protectedRoot,
                didReadBytes: didReadBytes
            )
            try Data("external replacement".utf8).write(to: target.url, options: .atomic)
            return snapshot
        })
    }

    private struct Fixture: Sendable {
        let parent: URL
        let vault: URL
        let safe: URL
        let retired: URL
        let outside: URL
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCRUDContainmentRaceTests-\(UUID().uuidString)", isDirectory: true)
        let vault = parent.appendingPathComponent("vault", isDirectory: true)
        let safe = vault.appendingPathComponent("notes/safe", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: safe.appendingPathComponent("a.log"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("a.log"))
        return Fixture(
            parent: parent, vault: vault, safe: safe,
            retired: vault.appendingPathComponent("notes/retired", isDirectory: true),
            outside: outside
        )
    }

    private func racingStore(_ fixture: Fixture) -> VaultCRUDStore {
        VaultCRUDStore(vaultPath: fixture.vault.path, snapshotLoader: { target, maximumBytes, protectedRoot, didReadBytes in
            let snapshot = try VaultFileInspector.snapshot(
                target, maximumBytes: maximumBytes, rejectHiddenDescendantsOf: protectedRoot,
                didReadBytes: didReadBytes
            )
            try FileManager.default.moveItem(at: fixture.safe, to: fixture.retired)
            try FileManager.default.createSymbolicLink(at: fixture.safe, withDestinationURL: fixture.outside)
            return snapshot
        })
    }
}
