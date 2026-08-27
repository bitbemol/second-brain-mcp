import Foundation
import MCP
import Testing
@testable import second_brain_mcp

@Suite("Link query scalability regressions")
struct LinkQueryScalabilityTests {
    @Test("Default backlinks group occurrences by source without losing exact formats")
    func backlinksGroupSources() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[[Target]] [[Target|alias]] ![[Target]]", to: "notes/A.md", under: root)
        try write("[[Target]]", to: "notes/B.md", under: root)
        try write("# Target", to: "notes/Target.md", under: root)

        let response = try await controller(root).call(.init(
            name: "query_links",
            arguments: ["direction": .string("backlinks"), "target": .string("Target")]
        ))
        #expect(response.isError != true)
        let output = try #require(response.structuredContent?.objectValue)
        let results = try #require(output["results"]?.arrayValue)
        #expect(results.count == 2)
        let first = try #require(results.first?.objectValue)
        #expect(first["source_path"]?.stringValue == "notes/A.md")
        #expect(first["resolved_path"]?.stringValue == "notes/Target.md")
        #expect(first["resolved_format"]?.stringValue == "markdown")
        #expect(first["occurrence_count"]?.intValue == 3)
        #expect(first["target"] == nil)
        #expect(first["alias"] == nil)
        #expect(first["kind"] == nil)
        #expect(output["coverage"]?.objectValue?["complete"]?.boolValue == true)
    }

    @Test("Selected backlink occurrence drilldown opens only the selected source")
    func occurrenceDrilldownSelectsSource() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[[Target]] [[Target|alias]]", to: "notes/A.md", under: root)
        try write("[[Target]]", to: "notes/B.md", under: root)
        try write("# Target", to: "notes/Target.md", under: root)
        let probe = SnapshotProbe()
        let response = try await controller(root, probe: probe).call(.init(
            name: "query_links",
            arguments: [
                "direction": .string("backlinks"), "target": .string("Target"),
                "group_by": .string("occurrence"), "source_path": .string("notes/A.md"),
            ]
        ))
        #expect(response.isError != true)
        let results = try #require(response.structuredContent?.objectValue?["results"]?.arrayValue)
        #expect(results.count == 2)
        #expect(results.compactMap { $0.objectValue?["occurrence"]?.intValue } == [1, 2])
        #expect(probe.paths == ["notes/A.md"])
    }

    @Test("Backlinks examine valid sources beyond the former aggregate byte ceiling")
    func backlinksBeyondFormerByteCeiling() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("# Target", to: "notes/Target.md", under: root)
        var document = Data("[[Target]]\n".utf8)
        document.append(Data(repeating: 0x20, count: 8 * 1_024 * 1_024 - document.count))
        for index in 0..<9 {
            try document.write(to: root.appendingPathComponent("notes/source-\(index).md"))
        }

        let response = try await controller(root).call(.init(
            name: "query_links",
            arguments: ["direction": .string("backlinks"), "target": .string("Target")]
        ))
        #expect(response.isError != true)
        let output = try #require(response.structuredContent?.objectValue)
        let sources = try #require(output["results"]?.arrayValue)
            .compactMap { $0.objectValue?["source_path"]?.stringValue }
        #expect(sources == (0..<9).map { "notes/source-\($0).md" })
        #expect(output["coverage"]?.objectValue?["complete"]?.boolValue == true)
    }

    @Test("Malformed source coverage does not hide healthy backlinks")
    func malformedSourceIsIsolated() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[[Target]]", to: "notes/healthy.md", under: root)
        try write("# Target", to: "notes/Target.md", under: root)
        try Data([0xff]).write(to: root.appendingPathComponent("notes/broken.md"))

        let response = try await controller(root).call(.init(
            name: "query_links",
            arguments: ["direction": .string("backlinks"), "target": .string("Target")]
        ))
        #expect(response.isError != true)
        let output = try #require(response.structuredContent?.objectValue)
        let sources = try #require(output["results"]?.arrayValue)
            .compactMap { $0.objectValue?["source_path"]?.stringValue }
        #expect(sources == ["notes/healthy.md"])
        let coverage = try #require(output["coverage"]?.objectValue)
        #expect(coverage["complete"]?.boolValue == false)
        #expect(coverage["failed_files"]?.intValue == 1)
        #expect(coverage["samples"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            == "notes/broken.md")
    }

    @Test("Outgoing cursor rejects raw source changes even if links are unchanged")
    func outgoingCursorTracksSourceRevision() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[[First]] [[Second]]", to: "notes/Source.md", under: root)
        try write("# First", to: "notes/First.md", under: root)
        try write("# Second", to: "notes/Second.md", under: root)
        let tools = controller(root)
        let first = try await tools.call(.init(
            name: "query_links",
            arguments: [
                "direction": .string("outgoing"), "target": .string("notes/Source.md"),
                "limit": .int(1),
            ]
        ))
        let cursor = try #require(first.structuredContent?.objectValue?["next_cursor"]?.stringValue)
        try write("[[First]] [[Second]]\nChanged prose", to: "notes/Source.md", under: root)
        let next = try await tools.call(.init(
            name: "query_links",
            arguments: [
                "direction": .string("outgoing"), "target": .string("notes/Source.md"),
                "limit": .int(1), "cursor": .string(cursor),
            ]
        ))
        #expect(next.isError == true)
        let text = next.content.compactMap { block -> String? in
            guard case .text(let value, _, _) = block else { return nil }
            return value
        }.joined()
        #expect(text.contains("stale"))
    }

    @Test("Malformed link cursors are rejected before opening source bytes")
    func malformedCursorDoesNotOpenSources() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[[Target]]", to: "notes/Source.md", under: root)
        try write("# Target", to: "notes/Target.md", under: root)
        let probe = SnapshotProbe()
        let response = try await controller(root, probe: probe).call(.init(
            name: "query_links",
            arguments: [
                "direction": .string("outgoing"), "target": .string("notes/Source.md"),
                "cursor": .string("not-a-valid-cursor"),
            ]
        ))
        #expect(response.isError == true)
        #expect(probe.paths.isEmpty)
    }

    @Test("Resolve-only namespace refuses symlinked area roots without exposing outside names")
    func resolveRejectsSymlinkedAreaRoots() async throws {
        for area in ["notes", "references"] {
            let root = try makeVault()
            defer { try? FileManager.default.removeItem(at: root) }
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("LinkQueryOutside-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            let name = area == "notes" ? "Outside.md" : "Outside.pdf"
            try Data("outside".utf8).write(to: outside.appendingPathComponent(name))
            let areaURL = root.appendingPathComponent(area)
            try FileManager.default.removeItem(at: areaURL)
            try FileManager.default.createSymbolicLink(at: areaURL, withDestinationURL: outside)

            let result = try await controller(root).call(.init(
                name: "query_links",
                arguments: ["direction": .string("resolve"), "target": .string(name)]
            ))
            #expect(result.isError == true)
            #expect(result.structuredContent == nil)
            let text = result.content.compactMap { block -> String? in
                guard case .text(let value, _, _) = block else { return nil }
                return value
            }.joined()
            #expect(!text.contains(outside.path))
        }
    }

    private func controller(_ root: URL, probe: SnapshotProbe? = nil) -> LinkQueryToolController {
        let store = VaultCRUDStore(vaultPath: root.path, snapshotLoader: {
            target, maximumBytes, protectedRoot, didReadBytes in
            probe?.record(target.relativePath)
            return try VaultFileInspector.snapshot(
                target, maximumBytes: maximumBytes,
                rejectHiddenDescendantsOf: protectedRoot,
                didReadBytes: didReadBytes
            )
        })
        let engine = VaultLinkQueryEngine(
            vaultPath: root.path,
            capabilities: FileCapabilities(formats: [
                .init(format: .markdown, operations: [.read: [.notes]]),
                .init(format: .pdf, operations: [.read: [.references]]),
            ]),
            store: store,
            access: VaultAccessCoordinator(lockURL: root.appendingPathComponent(".vault-access.lock"))
        )
        return LinkQueryToolController(links: engine)
    }

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkQueryScalabilityTests-\(UUID().uuidString)")
        for area in ["notes", "references"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(area), withIntermediateDirectories: true
            )
        }
        return root
    }

    private func write(_ text: String, to path: String, under root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private final class SnapshotProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        var paths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func record(_ path: String) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(path)
        }
    }
}
