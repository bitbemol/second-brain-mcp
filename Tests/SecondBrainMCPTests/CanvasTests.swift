import Testing
import Foundation
@testable import SecondBrainMCP

// MARK: - CanvasModel validation

@Suite("CanvasModel — validation")
struct CanvasModelTests {

    private func validate(_ json: String) throws {
        try CanvasModel.validate(jsonData: Data(json.utf8))
    }

    @Test("Valid canvas with nodes and edges passes")
    func valid() throws {
        try validate("""
        {"nodes":[
          {"id":"a","type":"text","x":0,"y":0,"width":200,"height":60,"text":"Hello"},
          {"id":"b","type":"file","x":0,"y":100,"width":200,"height":60,"file":"notes/x.md","subpath":"#section"},
          {"id":"c","type":"link","x":0,"y":200,"width":200,"height":60,"url":"https://example.com"},
          {"id":"d","type":"group","x":0,"y":300,"width":400,"height":200,"label":"Group","backgroundStyle":"cover","color":"4"}
        ],
        "edges":[{"id":"e1","fromNode":"a","toNode":"b","fromSide":"bottom","toEnd":"arrow","color":"#FF0000"}]}
        """)
    }

    @Test("Empty canvas passes")
    func empty() throws {
        try validate("{}")
        try validate(#"{"nodes":[],"edges":[]}"#)
    }

    @Test("Malformed JSON is rejected")
    func malformed() {
        #expect(throws: CanvasModel.CanvasError.self) { try validate("{not json") }
    }

    @Test("Duplicate node id is rejected")
    func duplicateID() {
        #expect(throws: CanvasModel.CanvasError.self) {
            try validate("""
            {"nodes":[
              {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"one"},
              {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"two"}
            ]}
            """)
        }
    }

    @Test("Edge referencing a missing node is rejected")
    func danglingEdge() {
        #expect(throws: CanvasModel.CanvasError.self) {
            try validate("""
            {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"hi"}],
             "edges":[{"id":"e","fromNode":"a","toNode":"ghost"}]}
            """)
        }
    }

    @Test("Unknown node type is rejected")
    func unknownType() {
        #expect(throws: CanvasModel.CanvasError.self) {
            try validate(#"{"nodes":[{"id":"a","type":"sticky","x":0,"y":0,"width":1,"height":1}]}"#)
        }
    }

    @Test("Missing required geometry is rejected")
    func missingGeometry() {
        #expect(throws: CanvasModel.CanvasError.self) {
            try validate(#"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"text":"hi"}]}"#)
        }
    }

    @Test("Invalid enum values are rejected")
    func badEnums() {
        #expect(throws: CanvasModel.CanvasError.self) {
            try validate(#"{"nodes":[{"id":"g","type":"group","x":0,"y":0,"width":1,"height":1,"backgroundStyle":"wrong"}]}"#)
        }
        #expect(throws: CanvasModel.CanvasError.self) {
            try validate("""
            {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x"},
                      {"id":"b","type":"text","x":0,"y":0,"width":1,"height":1,"text":"y"}],
             "edges":[{"id":"e","fromNode":"a","toNode":"b","fromSide":"diagonal"}]}
            """)
        }
    }

    @Test("Invalid color is rejected")
    func badColor() {
        #expect(throws: CanvasModel.CanvasError.self) {
            try validate(##"{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x","color":"#zz"}]}"##)
        }
    }

    @Test("Unknown extra keys are accepted (forward-compat)")
    func extraKeysAccepted() throws {
        try validate("""
        {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x","pluginField":42}],
         "customTopLevel":{"foo":"bar"}}
        """)
    }
}

// MARK: - CanvasManager I/O

@Suite("CanvasManager — CRUD")
struct CanvasManagerTests {

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "CanvasManagerTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        return root
    }

    private let sample = """
    {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":200,"height":60,"text":"First node"}],"edges":[]}
    """

    @Test("Create, read, replace, delete round-trip")
    func roundTrip() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)

        _ = try await mgr.create(relativePath: "notes/boards/board.canvas", json: sample)

        let summary = try await mgr.read(relativePath: "notes/boards/board.canvas")
        #expect(summary.nodeCount == 1)
        #expect(summary.edgeCount == 0)
        #expect(summary.nodes.first?.type == "text")
        #expect(summary.nodes.first?.label == "First node")

        let updated = """
        {"nodes":[
          {"id":"a","type":"text","x":0,"y":0,"width":200,"height":60,"text":"First"},
          {"id":"b","type":"link","x":0,"y":100,"width":200,"height":60,"url":"https://x.com"}
        ],"edges":[{"id":"e","fromNode":"a","toNode":"b"}]}
        """
        _ = try await mgr.replace(relativePath: "notes/boards/board.canvas", json: updated)
        let after = try await mgr.read(relativePath: "notes/boards/board.canvas")
        #expect(after.nodeCount == 2)
        #expect(after.edgeCount == 1)

        _ = try await mgr.delete(relativePath: "notes/boards/board.canvas")
        #expect(FileManager.default.fileExists(atPath: root + "/notes/boards/board.canvas") == false)
        let trash = (try? FileManager.default.contentsOfDirectory(atPath: root + "/.trash")) ?? []
        #expect(trash.contains { $0.hasSuffix("_board.canvas") })
    }

    @Test("Create rejects a path that already exists")
    func createExisting() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        _ = try await mgr.create(relativePath: "notes/a.canvas", json: sample)
        await #expect(throws: CanvasManager.CanvasManagerError.self) {
            try await mgr.create(relativePath: "notes/a.canvas", json: sample)
        }
    }

    @Test("Create rejects invalid canvas content")
    func createInvalid() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        await #expect(throws: (any Error).self) {
            try await mgr.create(relativePath: "notes/bad.canvas", json: "{not valid")
        }
        #expect(FileManager.default.fileExists(atPath: root + "/notes/bad.canvas") == false)
    }

    @Test("Update rejects a missing file")
    func updateMissing() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        await #expect(throws: CanvasManager.CanvasManagerError.self) {
            try await mgr.replace(relativePath: "notes/nope.canvas", json: sample)
        }
    }

    @Test("Non-notes prefix and wrong extension are rejected")
    func pathGuards() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        await #expect(throws: CanvasManager.CanvasManagerError.self) {
            try await mgr.create(relativePath: "references/x.canvas", json: sample)
        }
        await #expect(throws: CanvasManager.CanvasManagerError.self) {
            try await mgr.create(relativePath: "notes/x.md", json: sample)
        }
    }

    @Test("Unknown keys survive a write (lossless, original bytes)")
    func fidelity() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        let withExtra = """
        {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"x","styleAttributes":{"k":"v"}}],"obsidianMeta":{"version":7}}
        """
        _ = try await mgr.create(relativePath: "notes/keep.canvas", json: withExtra)
        let onDisk = try String(contentsOfFile: root + "/notes/keep.canvas", encoding: .utf8)
        #expect(onDisk.contains("styleAttributes"))
        #expect(onDisk.contains("obsidianMeta"))
        #expect(onDisk == withExtra)
    }
}

// MARK: - CanvasManager listing & flags

@Suite("CanvasManager — listing & flags")
struct CanvasListingTests {

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "CanvasListing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes/boards", withIntermediateDirectories: true)
        return root
    }

    @Test("listCanvases returns counts and a per-type breakdown")
    func list() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        let c1 = """
        {"nodes":[
          {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"hi"},
          {"id":"b","type":"text","x":0,"y":0,"width":1,"height":1,"text":"yo"},
          {"id":"g","type":"group","x":0,"y":0,"width":1,"height":1,"label":"G"}
        ],"edges":[{"id":"e","fromNode":"a","toNode":"b"}]}
        """
        _ = try await mgr.create(relativePath: "notes/boards/one.canvas", json: c1)
        _ = try await mgr.create(relativePath: "notes/two.canvas", json: #"{"nodes":[],"edges":[]}"#)

        let all = try await mgr.listCanvases()
        #expect(all.count == 2)
        let one = try #require(all.first { $0.relativePath == "notes/boards/one.canvas" })
        #expect(one.nodeCount == 3)
        #expect(one.edgeCount == 1)
        // 2 text, 1 group — sorted desc by count
        #expect(one.typeBreakdown.first?.type == "text")
        #expect(one.typeBreakdown.first?.count == 2)
    }

    @Test("listCanvases scopes to a subdirectory")
    func scoped() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        _ = try await mgr.create(relativePath: "notes/boards/one.canvas", json: #"{"nodes":[],"edges":[]}"#)
        _ = try await mgr.create(relativePath: "notes/two.canvas", json: #"{"nodes":[],"edges":[]}"#)
        let scoped = try await mgr.listCanvases(directory: "notes/boards")
        #expect(scoped.map(\.relativePath) == ["notes/boards/one.canvas"])
    }

    @Test("read_canvas flags a file-node whose target is missing")
    func brokenFileNode() async throws {
        let root = try makeVault()
        try "x".write(toFile: root + "/notes/real.md", atomically: true, encoding: .utf8)
        let mgr = CanvasManager(vaultPath: root)
        let canvas = """
        {"nodes":[
          {"id":"ok","type":"file","x":0,"y":0,"width":1,"height":1,"file":"notes/real.md"},
          {"id":"bad","type":"file","x":0,"y":0,"width":1,"height":1,"file":"notes/ghost.md"}
        ],"edges":[]}
        """
        _ = try await mgr.create(relativePath: "notes/board.canvas", json: canvas)
        let summary = try await mgr.read(relativePath: "notes/board.canvas")
        let ok = try #require(summary.nodes.first { $0.id == "ok" })
        let bad = try #require(summary.nodes.first { $0.id == "bad" })
        #expect(ok.warning == nil)
        #expect(bad.warning == "file not found")
    }
}

// MARK: - CanvasManager search

@Suite("CanvasManager — search")
struct CanvasSearchTests {

    private func makeVault() throws -> String {
        let root = NSTemporaryDirectory() + "CanvasSearch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/notes/boards", withIntermediateDirectories: true)
        return root
    }

    /// A canvas exercising every node kind: text, group (label), file, link. The
    /// term "falcon" appears in all four — only the text node and group label
    /// should be considered in-scope.
    private func seedCanvas() -> String {
        """
        {"nodes":[
          {"id":"t1","type":"text","x":0,"y":0,"width":200,"height":60,"text":"Roadmap for the Falcon launch"},
          {"id":"t2","type":"text","x":0,"y":80,"width":200,"height":60,"text":"unrelated note"},
          {"id":"g1","type":"group","x":0,"y":160,"width":400,"height":200,"label":"Falcon milestones"},
          {"id":"f1","type":"file","x":0,"y":380,"width":200,"height":60,"file":"notes/falcon-spec.md"},
          {"id":"l1","type":"link","x":0,"y":460,"width":200,"height":60,"url":"https://falcon.example.com"}
        ],"edges":[]}
        """
    }

    @Test("Matches text-node text and group label, case-insensitively")
    func matchesTextAndLabel() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        _ = try await mgr.create(relativePath: "notes/boards/board.canvas", json: seedCanvas())

        let r = try await mgr.search(query: "FALCON")            // upper-case query, lower-case content
        #expect(Set(r.hits.map(\.nodeID)) == ["t1", "g1"])       // text node + group label only
        #expect(r.hits.contains { $0.nodeID == "t1" && $0.field == "text" })
        #expect(r.hits.contains { $0.nodeID == "g1" && $0.field == "label" })
    }

    @Test("File and link node references are out of scope (Tier 2)")
    func ignoresFileAndLink() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        _ = try await mgr.create(relativePath: "notes/boards/board.canvas", json: seedCanvas())

        // "example" lives only in the link URL; "spec" only in the file path.
        #expect(try await mgr.search(query: "example").hits.isEmpty)
        #expect(try await mgr.search(query: "spec").hits.isEmpty)
    }

    @Test("Snippet carries context around the match")
    func snippetContext() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        _ = try await mgr.create(relativePath: "notes/boards/board.canvas", json: seedCanvas())

        let hit = try #require(try await mgr.search(query: "roadmap").hits.first { $0.nodeID == "t1" })
        #expect(hit.snippet.lowercased().contains("roadmap for the falcon launch"))
    }

    @Test("max_results caps hits but totalMatches reports the true count")
    func capping() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        let json = """
        {"nodes":[
          {"id":"a","type":"text","x":0,"y":0,"width":1,"height":1,"text":"match one"},
          {"id":"b","type":"text","x":0,"y":0,"width":1,"height":1,"text":"match two"},
          {"id":"c","type":"text","x":0,"y":0,"width":1,"height":1,"text":"match three"}
        ],"edges":[]}
        """
        _ = try await mgr.create(relativePath: "notes/boards/many.canvas", json: json)
        let r = try await mgr.search(query: "match", maxResults: 2)
        #expect(r.hits.count == 2)
        #expect(r.totalMatches == 3)
    }

    @Test("No match and empty query both return no hits")
    func emptyCases() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        _ = try await mgr.create(relativePath: "notes/boards/board.canvas", json: seedCanvas())
        #expect(try await mgr.search(query: "zzzznope").hits.isEmpty)
        #expect(try await mgr.search(query: "").hits.isEmpty)
    }

    @Test("Results span multiple canvases, ordered by path")
    func multipleCanvases() async throws {
        let root = try makeVault()
        let mgr = CanvasManager(vaultPath: root)
        _ = try await mgr.create(relativePath: "notes/boards/b.canvas",
                                 json: #"{"nodes":[{"id":"n","type":"text","x":0,"y":0,"width":1,"height":1,"text":"alpha here"}],"edges":[]}"#)
        _ = try await mgr.create(relativePath: "notes/a.canvas",
                                 json: #"{"nodes":[{"id":"m","type":"text","x":0,"y":0,"width":1,"height":1,"text":"alpha too"}],"edges":[]}"#)
        let r = try await mgr.search(query: "alpha")
        #expect(r.hits.map(\.relativePath) == ["notes/a.canvas", "notes/boards/b.canvas"])
    }
}
