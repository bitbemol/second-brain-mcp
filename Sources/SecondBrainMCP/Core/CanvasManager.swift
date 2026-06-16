import Foundation

/// Sandboxed CRUD for Obsidian `.canvas` files (JSON Canvas 1.0). Actor because
/// file operations must be serialized, mirroring `VaultManager`.
///
/// Canvas files live under `notes/` — writable, git-tracked user content — so they
/// reuse the same path gate, soft-delete, and git machinery as notes. Writes
/// validate via `CanvasModel` and then persist the caller's **original bytes**
/// (lossless: plugin-added keys outside the 1.0 spec survive).
actor CanvasManager {

    private let vaultPath: String

    enum CanvasManagerError: Error, CustomStringConvertible {
        case invalidPath(String)
        case notFound(String)
        case alreadyExists(String)
        case readFailed(String, underlying: String)

        var description: String {
            switch self {
            case .invalidPath(let reason): return "Invalid path: \(reason)"
            case .notFound(let path): return "Canvas not found: \(path)"
            case .alreadyExists(let path): return "Canvas already exists: \(path)"
            case .readFailed(let path, let underlying): return "Failed to read \(path): \(underlying)"
            }
        }
    }

    struct NodeBrief: Sendable {
        let id: String
        let type: String
        let label: String
    }

    struct CanvasSummary: Sendable {
        let relativePath: String
        let nodeCount: Int
        let edgeCount: Int
        let nodes: [NodeBrief]
        let rawJSON: String
    }

    init(vaultPath: String) {
        self.vaultPath = vaultPath
    }

    // MARK: - Read

    /// Read a canvas: lenient summary (counts + per-node briefs) plus raw JSON.
    /// Reads don't run strict validation — the file is already on disk and a
    /// best-effort view is more useful than failing on a slightly-off canvas.
    func read(relativePath: String) throws -> CanvasSummary {
        let resolved = try resolveCanvasPath(relativePath)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw CanvasManagerError.notFound(relativePath)
        }

        let content: String
        do {
            content = try String(contentsOfFile: resolved, encoding: .utf8)
        } catch {
            throw CanvasManagerError.readFailed(relativePath, underlying: error.localizedDescription)
        }

        let (nodeCount, edgeCount, briefs) = summarize(content)
        return CanvasSummary(
            relativePath: relativePath,
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            nodes: briefs,
            rawJSON: content
        )
    }

    // MARK: - Write

    /// Create a new canvas. Path must not already exist. Validates before writing.
    func create(relativePath: String, json: String) throws -> String {
        let resolved = try resolveCanvasPath(relativePath)
        guard !FileManager.default.fileExists(atPath: resolved) else {
            throw CanvasManagerError.alreadyExists(relativePath)
        }
        try CanvasModel.validate(jsonData: Data(json.utf8))

        let parentDir = (resolved as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        try json.write(toFile: resolved, atomically: true, encoding: .utf8)
        return "Created: \(relativePath)"
    }

    /// Replace an existing canvas's entire contents. Validates before writing.
    func replace(relativePath: String, json: String) throws -> String {
        let resolved = try resolveCanvasPath(relativePath)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw CanvasManagerError.notFound(relativePath)
        }
        try CanvasModel.validate(jsonData: Data(json.utf8))

        try json.write(toFile: resolved, atomically: true, encoding: .utf8)
        return "Updated: \(relativePath)"
    }

    // MARK: - Delete

    /// Soft-delete a canvas by moving it to `.trash/` (mirrors `VaultManager.deleteNote`).
    func delete(relativePath: String) throws -> String {
        let resolved = try resolveCanvasPath(relativePath)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw CanvasManagerError.notFound(relativePath)
        }

        let trashDir = vaultPath + "/.trash"
        try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = (resolved as NSString).lastPathComponent
        let trashPath = trashDir + "/\(timestamp)_\(filename)"

        try FileManager.default.moveItem(atPath: resolved, toPath: trashPath)
        return "Deleted: \(relativePath) → .trash/\(timestamp)_\(filename)"
    }

    // MARK: - Private

    /// Both the `notes/` prefix and the `.canvas` extension are required.
    private func resolveCanvasPath(_ relativePath: String) throws -> String {
        guard relativePath.hasPrefix("notes/") else {
            throw CanvasManagerError.invalidPath("Path must be within notes/: \(relativePath)")
        }
        do {
            return try PathValidator.resolve(
                relativePath: relativePath,
                root: vaultPath,
                allowedExtensions: ["canvas"]
            )
        } catch {
            throw CanvasManagerError.invalidPath("\(error)")
        }
    }

    /// Best-effort summary for `read`. Never throws — returns zeros for content
    /// that isn't a JSON Canvas object.
    private func summarize(_ json: String) -> (nodeCount: Int, edgeCount: Int, briefs: [NodeBrief]) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0, [])
        }
        let nodes = root["nodes"] as? [[String: Any]] ?? []
        let edges = root["edges"] as? [[String: Any]] ?? []

        let briefs: [NodeBrief] = nodes.compactMap { node in
            guard let id = node["id"] as? String, let type = node["type"] as? String else { return nil }
            return NodeBrief(id: id, type: type, label: label(for: node, type: type))
        }
        return (nodes.count, edges.count, briefs)
    }

    private func label(for node: [String: Any], type: String) -> String {
        switch type {
        case "group": return (node["label"] as? String) ?? "(group)"
        case "file": return (node["file"] as? String) ?? ""
        case "link": return (node["url"] as? String) ?? ""
        case "text":
            let text = (node["text"] as? String) ?? ""
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        default: return ""
        }
    }
}
