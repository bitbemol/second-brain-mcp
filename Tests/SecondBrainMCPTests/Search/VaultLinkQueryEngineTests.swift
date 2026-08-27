import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `Vault link query engine` {
    @Test
    func `Resolve returns every ambiguous basename with the nearest candidate first`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Local", to: "notes/project/Target.md", under: root)
        try write("# Remote", to: "notes/archive/Target.md", under: root)
        try write("# Source", to: "notes/project/Source.md", under: root)

        let response = try await makeEngine(root: root).query(LinkQueryRequest(
            direction: .resolve,
            target: "[[Target|display name]]",
            fromPath: "notes/project/Source.md"
        ))

        #expect(response.direction == .resolve)
        #expect(response.nextCursor == nil)
        #expect(response.results.map(\.resolvedPath) == [
            "notes/project/Target.md",
            "notes/archive/Target.md",
        ])
        let allAmbiguous = response.results.allSatisfy(\.ambiguous)
        let allTargetsMatch = response.results.allSatisfy { $0.target == "Target" }
        let allAliasesMatch = response.results.allSatisfy { $0.alias == "display name" }
        let allKindsMatch = response.results.allSatisfy { $0.kind == .link }
        let allSourcesAreAbsent = response.results.allSatisfy { $0.sourcePath == nil }
        #expect(allAmbiguous)
        #expect(allTargetsMatch)
        #expect(allAliasesMatch)
        #expect(allKindsMatch)
        #expect(allSourcesAreAbsent)
    }

    @Test
    func `Exact source and target paths do not collapse diacritic collisions`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("[[First]]", to: "notes/cafe.md", under: root)
        try write("[[Second]]", to: "notes/café.md", under: root)
        try write("# First", to: "notes/First.md", under: root)
        try write("# Second", to: "notes/Second.md", under: root)
        let engine = makeEngine(root: root)

        for (path, linkedPath) in [
            ("notes/cafe.md", "notes/First.md"),
            ("notes/café.md", "notes/Second.md"),
        ] {
            let resolved = try await engine.query(LinkQueryRequest(
                direction: .resolve,
                target: path
            ))
            #expect(resolved.results.map(\.resolvedPath) == [path])
            #expect(resolved.results.allSatisfy { !$0.ambiguous })

            let outgoing = try await engine.query(LinkQueryRequest(
                direction: .outgoing,
                target: path
            ))
            #expect(outgoing.results.map(\.sourcePath) == [path])
            #expect(outgoing.results.map(\.resolvedPath) == [linkedPath])

            let selfLink = try await engine.query(LinkQueryRequest(
                direction: .resolve,
                target: "#Heading",
                fromPath: path
            ))
            #expect(selfLink.results.map(\.resolvedPath) == [path])
        }
    }

    @Test
    func `Folded explicit targets retain ambiguity without choosing a source`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Plain", to: "notes/cafe.md", under: root)
        try write("# Accent", to: "notes/café.md", under: root)
        let engine = makeEngine(root: root)

        let resolved = try await engine.query(LinkQueryRequest(
            direction: .resolve,
            target: "notes/càfe.md"
        ))
        #expect(resolved.results.map(\.resolvedPath) == ["notes/cafe.md", "notes/café.md"])
        let allAmbiguous = resolved.results.allSatisfy(\.ambiguous)
        #expect(allAmbiguous)

        var rejectedSource = false
        do {
            _ = try await engine.query(LinkQueryRequest(
                direction: .outgoing,
                target: "notes/càfe.md"
            ))
        } catch LinkQueryError.invalidTarget {
            rejectedSource = true
        }
        #expect(rejectedSource)

        var rejectedContext = false
        do {
            _ = try await engine.query(LinkQueryRequest(
                direction: .resolve,
                target: "#Heading",
                fromPath: "notes/càfe.md"
            ))
        } catch LinkQueryError.invalidFromPath {
            rejectedContext = true
        }
        #expect(rejectedContext)
    }

    @Test
    func `Distinct width and case paths retain exact identity when supported`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        for (index, names) in [
            ("cafe.md", "ｃａｆｅ.md"),
            ("Source.md", "source.md"),
        ].enumerated() {
            let firstPath = "notes/collision-\(index)/\(names.0)"
            let secondPath = "notes/collision-\(index)/\(names.1)"
            try write("# First", to: firstPath, under: root)
            // A case-insensitive filesystem cannot represent both case variants.
            guard !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(secondPath).path
            ) else { continue }
            try write("# Second", to: secondPath, under: root)

            for path in [firstPath, secondPath] {
                let response = try await makeEngine(root: root).query(LinkQueryRequest(
                    direction: .resolve,
                    target: path
                ))
                #expect(response.results.map(\.resolvedPath) == [path])
                #expect(response.results.allSatisfy { !$0.ambiguous })
            }
        }
    }

    @Test
    func `Unique folded path spellings preserve compatibility`() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Target", to: "notes/Project/Target.md", under: root)
        try write("[[Target]]", to: "notes/Project/Source.md", under: root)
        let engine = makeEngine(root: root)

        let resolved = try await engine.query(LinkQueryRequest(
            direction: .resolve,
            target: "notes/project/target.md",
            fromPath: "notes/PROJECT/SOURCE.md"
        ))
        #expect(resolved.results.map(\.resolvedPath) == ["notes/Project/Target.md"])

        let outgoing = try await engine.query(LinkQueryRequest(
            direction: .outgoing,
            target: "notes/project/source.md"
        ))
        #expect(outgoing.results.map(\.sourcePath) == ["notes/Project/Source.md"])
        #expect(outgoing.results.map(\.resolvedPath) == ["notes/Project/Target.md"])
    }

    private func makeEngine(root: URL) -> VaultLinkQueryEngine {
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
            .init(format: .png, operations: [.read: [.notes, .references]]),
            .init(format: .pdf, operations: [.read: [.references]]),
        ])
        return VaultLinkQueryEngine(
            vaultPath: root.path,
            capabilities: capabilities,
            store: VaultCRUDStore(vaultPath: root.path),
            access: VaultAccessCoordinator(
                lockURL: root.appendingPathComponent(".vault-access.lock")
            )
        )
    }

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLinkQueryEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func write(_ content: String, to path: String, under root: URL) throws {
        let destination = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: destination)
    }
}
