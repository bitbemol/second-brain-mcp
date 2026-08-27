import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Link namespace visibility")
struct LinkNamespaceVisibilityTests {
    @Test("Resolve rejects a Finder-hidden area root before returning namespace paths")
    func resolveRejectsFinderHiddenAreaRoots() async throws {
        for area in [VaultArea.notes, .references] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LinkNamespaceVisibility-\(UUID().uuidString)")
            let areaRoot = root.appendingPathComponent(area.rawValue)
            try FileManager.default.createDirectory(at: areaRoot, withIntermediateDirectories: true)
            defer {
                _ = Darwin.chflags(areaRoot.path, 0)
                try? FileManager.default.removeItem(at: root)
            }
            let format: FileFormat = area == .notes ? .markdown : .pdf
            let name = area == .notes ? "Target.md" : "Target.pdf"
            try Data("private namespace".utf8).write(to: areaRoot.appendingPathComponent(name))
            try #require(Darwin.chflags(areaRoot.path, UInt32(UF_HIDDEN)) == 0)
            let engine = VaultLinkQueryEngine(
                vaultPath: root.path,
                capabilities: FileCapabilities(formats: [
                    .init(format: format, operations: [.read: [area]])
                ]),
                store: VaultCRUDStore(vaultPath: root.path),
                access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
            )
            do {
                _ = try await engine.query(LinkQueryRequest(direction: .resolve, target: name))
                Issue.record("A hidden area must not yield a successful namespace query")
            } catch {
                // The selected invalid structural root must fail, never return its hidden paths.
            }
        }
    }
}
