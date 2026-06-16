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
