import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `External file source validation` {
    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "ExternalSource-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        return root
    }

    private func externalPath(_ name: String) -> String {
        NSTemporaryDirectory() + "ExternalSourceFile-\(UUID().uuidString)-\(name)"
    }

    @Test
    func `Resolves symbolic links and reports target size`() throws {
        let root = try makeVault()
        let target = externalPath("target.bin")
        let link = externalPath("alias.bin")
        try Data(count: 321).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: target
        )

        let source = try ExternalFileSourceValidator(vaultPath: root).validate(
            path: link,
            maximumBytes: 1_000
        )

        #expect(source.url.path == URL(fileURLWithPath: target).resolvingSymlinksInPath().path)
        #expect(source.byteCount == 321)
    }

    @Test
    func `Rejects missing and non-regular sources`() throws {
        let root = try makeVault()
        let validator = ExternalFileSourceValidator(vaultPath: root)

        #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try validator.validate(path: externalPath("missing.bin"), maximumBytes: 1_000)
        }

        let directory = externalPath("directory")
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try validator.validate(path: directory, maximumBytes: 1_000)
        }
    }

    @Test
    func `Rejects sources that resolve inside the vault`() throws {
        let root = try makeVault()
        let internalPath = root + "/notes/internal.bin"
        try Data([1]).write(to: URL(fileURLWithPath: internalPath))
        let link = externalPath("internal-link.bin")
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: internalPath
        )
        let validator = ExternalFileSourceValidator(vaultPath: root)

        #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            try validator.validate(path: link, maximumBytes: 1_000)
        }

        let similarPrefix = root + "-external.bin"
        try Data([1]).write(to: URL(fileURLWithPath: similarPrefix))
        #expect(try validator.validate(path: similarPrefix, maximumBytes: 1_000).url.path == similarPrefix)
    }

    @Test
    func `Applies the byte limit to a symbolic link target`() throws {
        let root = try makeVault()
        let target = externalPath("large.bin")
        let link = externalPath("large-link.bin")
        try Data(count: 2_000).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: target
        )

        do {
            _ = try ExternalFileSourceValidator(vaultPath: root).validate(
                path: link,
                maximumBytes: 1_000
            )
            Issue.record("Expected resolved target size rejection")
        } catch let error as ExternalFileSourceValidator.ValidationError {
            guard case .sourceTooLarge(bytes: 2_000, limit: 1_000) = error else {
                Issue.record("Unexpected validation error: \(error)")
                return
            }
        }
    }

    @Test
    func `Snapshots remain stable after the caller replaces the source`() throws {
        let root = try makeVault()
        let path = externalPath("changing.bin")
        try Data("original".utf8).write(to: URL(fileURLWithPath: path))
        let snapshot = try ExternalFileSourceValidator(vaultPath: root).snapshot(
            path: path,
            maximumBytes: 1_000
        )

        try Data("replacement".utf8).write(
            to: URL(fileURLWithPath: path),
            options: .atomic
        )

        #expect(try String(contentsOf: snapshot.url, encoding: .utf8) == "original")
        #expect(snapshot.byteCount == 8)
        let snapshotPath = snapshot.url.path
        snapshot.remove()
        #expect(!FileManager.default.fileExists(atPath: snapshotPath))
    }

    @Test
    func `Snapshots preserve legitimate external symbolic-link imports`() throws {
        let root = try makeVault()
        let target = externalPath("snapshot-target.bin")
        let link = externalPath("snapshot-link.bin")
        try Data("linked content".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: target
        )

        let snapshot = try ExternalFileSourceValidator(vaultPath: root).snapshot(
            path: link,
            maximumBytes: 1_000
        )
        defer { snapshot.remove() }
        #expect(try String(contentsOf: snapshot.url, encoding: .utf8) == "linked content")
    }

    @Test
    func `A parent replaced after validation cannot redirect the source open`() throws {
        let root = try makeVault()
        let sourceDirectory = URL(fileURLWithPath: externalPath("parent"))
        let movedDirectory = sourceDirectory.appendingPathExtension("moved")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let source = sourceDirectory.appendingPathComponent("marker.bin")
        try Data("external marker".utf8).write(to: source)
        let vaultMarker = URL(fileURLWithPath: root)
            .appendingPathComponent("notes/marker.bin")
        try Data("vault marker".utf8).write(to: vaultMarker)
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: movedDirectory)
            try? FileManager.default.removeItem(atPath: root)
        }

        #expect(throws: ExternalFileSourceValidator.ValidationError.self) {
            _ = try ExternalFileSourceValidator(vaultPath: root).snapshot(
                path: source.path,
                maximumBytes: 1_000,
                sourceDidValidate: {
                    try FileManager.default.moveItem(
                        at: sourceDirectory,
                        to: movedDirectory
                    )
                    try FileManager.default.createSymbolicLink(
                        at: sourceDirectory,
                        withDestinationURL: vaultMarker.deletingLastPathComponent()
                    )
                }
            )
        }
        #expect(try String(contentsOf: vaultMarker, encoding: .utf8) == "vault marker")
    }
}
