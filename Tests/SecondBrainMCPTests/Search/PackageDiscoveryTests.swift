import Foundation
import Testing
@testable import second_brain_mcp

@Suite("Consistent package discovery")
struct PackageDiscoveryTests {
    @Test("Whole-area search excludes nested packages just as explicit package scopes do")
    func searchExcludesPackageContents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let search = fixture.search()
        await #expect(throws: VaultSearchRequestError.self) {
            _ = try await search.search(VaultSearchRequest(
                location: .notes, directory: "Container.app", query: "needle"
            ))
        }

        let result = try await search.search(VaultSearchRequest(location: .notes, query: "needle"))

        #expect(result.results.map(\.path) == ["notes/Source.md"])
        #expect(result.coverage.complete)
        #expect(result.nextCursor == nil)
    }

    @Test("Recursive listing excludes package internals and still lists ordinary files")
    func listingExcludesPackageContents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let listing = fixture.listing()
        await #expect(throws: (any Error).self) {
            _ = try await listing.list(ListFilesRequest(area: .notes, directory: "Container.app"))
        }

        let result = try await listing.list(ListFilesRequest(area: .notes))

        #expect(result.files.map(\.path) == ["notes/Source.md", "notes/Target.md"])
        #expect(result.nextCursor == nil)
    }

    @Test("Resolve excludes package-only namespace entries without changing direct read authority")
    func resolveExcludesPackageContents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let links = fixture.links()
        let healthy = try await links.query(LinkQueryRequest(direction: .resolve, target: "Target"))
        #expect(healthy.results.compactMap(\.resolvedPath) == ["notes/Target.md"])

        let packaged = try await links.query(LinkQueryRequest(direction: .resolve, target: "PackageOnly"))

        #expect(packaged.results.compactMap(\.resolvedPath).isEmpty)
        #expect(packaged.coverage.complete)
        // Discovery exclusions do not revoke access to an explicitly named valid file.
        let target = try ReadableFileTarget.resolve(
            path: "notes/Container.app/Contents/PackageOnly.md",
            format: .markdown, vaultPath: fixture.root.path
        )
        let snapshot = try await VaultCRUDStore(vaultPath: fixture.root.path).snapshot(target)
        #expect(snapshot.data == Data("needle [[Target]]".utf8))
    }

    @Test("Backlinks never scan package internals as ordinary Markdown sources")
    func backlinksExcludePackageContents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.links().query(LinkQueryRequest(
            direction: .backlinks, target: "notes/Target.md"
        ))

        #expect(result.results.compactMap(\.sourcePath) == ["notes/Source.md"])
        #expect(result.results.map(\.occurrenceCount) == [1])
        #expect(result.coverage.complete)
        #expect(result.nextCursor == nil)
    }

    private struct Fixture {
        let root: URL
        let capabilities = FileCapabilities(formats: [
            .init(format: .markdown, operations: [.read: [.notes]]),
        ])

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PackageDiscoveryTests-\(UUID().uuidString)")
            let contents = root.appendingPathComponent("notes/Container.app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            do {
                let info = try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": "test.secondbrain.discovery",
                                       "CFBundlePackageType": "APPL"],
                    format: .xml, options: 0
                )
                try info.write(to: contents.appendingPathComponent("Info.plist"))
                try Data("needle [[Target]]".utf8)
                    .write(to: contents.appendingPathComponent("PackageOnly.md"))
                try Data("needle [[Target]]".utf8)
                    .write(to: root.appendingPathComponent("notes/Source.md"))
                try Data("# Target".utf8)
                    .write(to: root.appendingPathComponent("notes/Target.md"))
                let package = root.appendingPathComponent("notes/Container.app", isDirectory: true)
                let values = try package.resourceValues(forKeys: [.isPackageKey, .isDirectoryKey])
                try #require(values.isDirectory == true && values.isPackage == true,
                             "Fixture must be a real macOS package, not an ordinary directory")
            } catch {
                removeSearchFixture(root)
                throw error
            }
        }

        func access() -> VaultAccessCoordinator {
            VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
        }

        func search() -> VaultSearchEngine {
            VaultSearchEngine(source: SearchCorpusBuilder(
                vaultPath: root.path, capabilities: capabilities,
                captureStore: searchCaptureFixture(root), access: access()
            ))
        }

        func listing() -> VaultFileListingService {
            VaultFileListingService(vaultPath: root.path, capabilities: capabilities, access: access())
        }

        func links() -> VaultLinkQueryEngine {
            VaultLinkQueryEngine(
                vaultPath: root.path, capabilities: capabilities,
                store: VaultCRUDStore(vaultPath: root.path), access: access()
            )
        }

        func remove() { removeSearchFixture(root) }
    }
}
