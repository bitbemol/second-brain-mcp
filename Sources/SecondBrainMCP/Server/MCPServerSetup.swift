import Foundation
import MCP

/// Boot the MCP server, register all tool and resource handlers, start transport.
///
/// ## Startup Flow
/// 1. Create actors (VaultManager, ReferenceManager, AuditLogger) and SearchEngine
/// 2. Register all MCP handlers
/// 3. Start StdioTransport — server is now accepting client connections
///
/// No background indexing. Search uses on-demand disk grep (SSD-fast, zero memory).
struct MCPServerSetup {

    static func start(config: ServerConfig, gitManager: GitManager) async throws {
        // Migrate internal data (cache, logs, locks) from vault to ~/Library/Application Support/
        // so iCloud doesn't create corrupted duplicate directories.
        DataPaths.migrateFromVaultIfNeeded(vaultPath: config.vaultPath)

        let customInstructions = Self.loadCustomInstructions(vaultPath: config.vaultPath)
        let server = Server(
            name: "SecondBrainMCP",
            version: "1.0.0",
            instructions: """
            This is a personal knowledge vault with Markdown notes and PDF references. \
            Use the note tools to search, read, and manage notes. \
            Use the reference tools to search and read PDF books. \
            All note writes are automatically committed to git. \
            Paths are always relative to the vault root (e.g. "notes/projects/app.md").
            """ + (customInstructions.map { "\n\n" + $0 } ?? ""),
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        let vaultManager = VaultManager(config: config)
        let referenceManager = ReferenceManager(vaultPath: config.vaultPath)
        let searchEngine = SearchEngine(vaultPath: config.vaultPath)
        let auditLogger = AuditLogger(vaultPath: config.vaultPath)
        let imageManager = ImageManager(vaultPath: config.vaultPath, encoder: CoreGraphicsImageEncoder())
        let imageImporter = ImageImporter(vaultPath: config.vaultPath, encoder: CoreGraphicsImageEncoder())
        let canvasManager = CanvasManager(vaultPath: config.vaultPath)
        let attachmentManager = AttachmentManager(vaultPath: config.vaultPath)
        let linkResolver = LinkResolver(vaultPath: config.vaultPath)

        // ── Register handlers FIRST (before index is built) ──
        // This allows the server to accept connections immediately.

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.buildToolList(config: config))
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await Self.handleToolCall(
                params: params,
                vaultManager: vaultManager,
                referenceManager: referenceManager,
                searchEngine: searchEngine,
                gitManager: gitManager,
                config: config,
                auditLogger: auditLogger,
                imageManager: imageManager,
                canvasManager: canvasManager,
                attachmentManager: attachmentManager,
                linkResolver: linkResolver,
                imageImporter: imageImporter
            )
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [
                Resource(
                    name: "Vault Index",
                    uri: "secondbrain://index",
                    description: "Full vault index: all note paths, titles, and tags",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "Recent Notes",
                    uri: "secondbrain://recent",
                    description: "Notes modified in the last 7 days",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "Tags",
                    uri: "secondbrain://tags",
                    description: "All unique tags across the vault with note counts",
                    mimeType: "application/json"
                ),
                Resource(
                    name: "References Index",
                    uri: "secondbrain://references",
                    description: "All PDF references: paths, titles, authors, page counts",
                    mimeType: "application/json"
                )
            ])
        }

        await server.withMethodHandler(ReadResource.self) { params in
            switch params.uri {
            case "secondbrain://index":
                return try await Self.handleIndexResource(vaultManager: vaultManager)
            case "secondbrain://recent":
                return try await Self.handleRecentResource(vaultManager: vaultManager)
            case "secondbrain://tags":
                return try await Self.handleTagsResource(vaultManager: vaultManager)
            case "secondbrain://references":
                return Self.handleReferencesResource(referenceManager: referenceManager)
            default:
                throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
            }
        }

        // ── Start transport — server is now live ──
        let transport = StdioTransport()
        try await server.start(transport: transport)
        log("MCP server started, accepting connections")

        // ── Background: build lightweight cache for uncached PDFs ──
        // Caches metadata, page labels, search text + outline (TOC for long PDFs, full text for short ones).
        // Search works immediately using whatever cache exists on disk.
        Task {
            // Let the MCP handshake complete before heavy work
            try? await Task.sleep(for: .seconds(1))

            let stepStart = ContinuousClock.now
            referenceManager.ensureCacheExists()
            log("background: PDF cache check: \(stepStart.duration(to: .now))")
        }

        await server.waitUntilCompleted()
    }

    // MARK: - Custom Instructions

    private static func loadCustomInstructions(vaultPath: String) -> String? {
        let url = URL(fileURLWithPath: vaultPath).appendingPathComponent("INSTRUCTIONS.md")
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool Definitions

    private static func buildToolList(config: ServerConfig) -> [Tool] {
        var tools: [Tool] = []

        // -- Read tools (always registered) --

        tools.append(Tool(
            name: "read_note",
            description: "Read the full Markdown content of a note, including YAML frontmatter. Use get_note_metadata instead if you only need title, tags, or word count without loading the full content.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path from vault root (e.g. notes/projects/app.md)")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        // Cap at 20 notes per call. No per-note size limit — we trust users won't write
        // Don Quixote-length markdown files. Notes are typically small; the LLM's context
        // window is the natural backstop if someone goes wild.
        tools.append(Tool(
            name: "read_notes",
            description: "Read multiple notes in a single call (max 20). Returns a summary index (title + word count per note) followed by full content. Prefer this over multiple read_note calls when you need 2+ notes. Errors are reported per-note without failing the batch.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "paths": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Array of relative paths (e.g. [\"notes/foo.md\", \"notes/bar.md\"]). Maximum 20 per call.")
                    ])
                ]),
                "required": .array([.string("paths")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        tools.append(Tool(
            name: "list_notes",
            description: "List all notes with titles, tags, and modification dates — returns metadata only, not content. Use this to browse or discover notes. Filter by directory to scope to a folder, or by tag to find notes on a topic. Results sorted newest first. For finding notes by content, use search_notes instead.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Subdirectory to list (default: notes/)")
                    ]),
                    "recursive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include subdirectories (default: true)")
                    ]),
                    "tag": .object([
                        "type": .string("string"),
                        "description": .string("Filter by YAML frontmatter tag (case-insensitive)")
                    ])
                ])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        tools.append(Tool(
            name: "get_note_metadata",
            description: "Get a note's title, tags, created/modified dates, word count, and outgoing links — without loading the full content. Use this to check metadata before deciding whether to read the full note.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to the note")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        tools.append(Tool(
            name: "search_notes",
            description: "Keyword search across all notes by title and body content. Returns matching notes ranked by relevance with text snippets around matches. This is literal keyword matching — \"ML\" will NOT match \"machine learning\". Try multiple terms or variations if initial results are sparse.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search terms (literal keyword match, case-insensitive)")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Limit results (default: 20)")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ))

        tools.append(Tool(
            name: "read_canvas",
            description: "Read an Obsidian canvas (.canvas) file. Returns a summary (node and edge counts, and each node's id, type, and label) followed by the raw JSON Canvas content. Use this before update_canvas to see the current structure.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to a .canvas file (e.g. notes/boards/roadmap.canvas)")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "list_canvas",
            description: "List Obsidian canvas (.canvas) files with metadata only — node count, edge count, and a per-type node breakdown — not the raw JSON. Use this to discover canvases before read_canvas. Filter by directory to scope to a folder. Results sorted newest first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Subdirectory within notes/ to list (default: notes/)")
                    ]),
                    "recursive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include subdirectories (default: true)")
                    ])
                ])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "search_canvas",
            description: "Search Obsidian canvas (.canvas) files for a literal, case-insensitive keyword in text-node text and node/group labels. Returns matching canvases with the node id(s) and a snippet per match. Does NOT search file/link node references — use search_notes for note content. Use this to find which canvas mentions a term.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search term (literal keyword match, case-insensitive)")
                    ]),
                    "max_results": .object([
                        "type": .string("integer"),
                        "description": .string("Limit results (default: 20)")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "list_attachments",
            description: "List binary attachments — any file under notes/ that isn't a note (.md) or canvas (.canvas), e.g. images. Returns path, extension, size, and whether read_image can open it. Use this to discover images and other attachments, which list_notes does not show. Filter by directory to scope to a folder. Results sorted newest first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Subdirectory within notes/ to list (default: notes/)")
                    ]),
                    "recursive": .object([
                        "type": .string("boolean"),
                        "description": .string("Include subdirectories (default: true)")
                    ])
                ])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "resolve_link",
            description: "Resolve an Obsidian link or embed target to its actual vault path. Like Obsidian, a bare basename resolves vault-wide (e.g. an embed `![[screenshot.png]]` written in one folder can live in a different folder's _attachments). Accepts the target bare or wrapped (`foo.png`, `[[Some Note]]`, `![[img.png|alt]]`); an extension-less target resolves to a `.md` note. Returns the matching path(s), best match first; multiple means the basename is ambiguous. Use this to turn an embed you saw in a note into a path you can read_image / read_note.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "link": .object([
                        "type": .string("string"),
                        "description": .string("The link/embed target, e.g. \"screenshot.png\", \"[[Some Note]]\", or \"![[diagram.png|alt]]\"")
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "description": .string("Optional note path the link appears in (e.g. notes/apple/uikit/foo.md); used to break ambiguous basename ties by proximity")
                    ])
                ]),
                "required": .array([.string("link")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "find_backlinks",
            description: "Find every note that links to or embeds a given file — the reverse of resolve_link. Especially useful for non-note files: pass an image/attachment path (or bare basename) to see which notes embed it. Each candidate link is resolved before counting, so a basename shared by two files won't produce false hits. Accepts a vault-relative path (e.g. notes/apple/_attachments/foo.png) or a basename (foo.png).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("The file to find references to — a vault-relative path or a bare basename")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        // -- Write tools (only if not read-only) -- Phase 3
        if !config.readOnly {
            tools.append(Tool(
                name: "create_note",
                description: "Create a new note. Path must start with \"notes/\" and must not already exist. YAML frontmatter (title, created date, tags) is auto-generated if the content doesn't include it. Creates parent directories automatically. Git auto-commits.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path for the new file (e.g. notes/ideas/new-idea.md)")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("Markdown content")
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Tags to add to frontmatter")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("content")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "update_note",
                description: """
                    Update an existing note. Three modes: \
                    "replace" overwrites the ENTIRE note — only for small notes or complete rewrites. \
                    "append" adds content to the end. \
                    "patch" surgical find-and-replace edits — always use patch for notes longer than ~10 lines \
                    unless doing a full rewrite. \
                    Patch workflow: first read_note to get current content, then send patches with exact text \
                    from what you read. Include 2-3 surrounding lines in old_text if the target text is not \
                    unique (e.g. a common word or repeated pattern). Empty new_text deletes the matched text. \
                    Patches are applied sequentially and atomically — if any fail, nothing changes. \
                    Example — update a status and remove a TODO item: \
                    patches: [{"old_text": "## Status\\nIn progress", "new_text": "## Status\\nCompleted"}, \
                    {"old_text": "- Fix login bug\\n", "new_text": ""}]
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("New content (required for replace and append modes, ignored for patch mode)")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("replace"), .string("append"), .string("patch")]),
                            "description": .string("replace (default), append, or patch")
                        ]),
                        "patches": .object([
                            "type": .string("array"),
                            "description": .string("Array of {old_text, new_text} patches (required for patch mode). Each old_text must appear exactly once in the note. Empty new_text deletes the matched text. Max 20 patches per call."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "old_text": .object([
                                        "type": .string("string"),
                                        "description": .string("Exact text to find (must appear exactly once). Include 2-3 surrounding lines for uniqueness if the text alone could match multiple locations.")
                                    ]),
                                    "new_text": .object([
                                        "type": .string("string"),
                                        "description": .string("Replacement text (empty string to delete)")
                                    ])
                                ]),
                                "required": .array([.string("old_text"), .string("new_text")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("path")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "move_note",
                description: "Move or rename a single note within notes/. Creates destination parent directories automatically and cleans up empty source directories. Cannot overwrite an existing note. Supports case-only renames (e.g. Foo.md to foo.md). Git auto-commits.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Current relative path (e.g. notes/ideas/ml-stuff.md)")
                        ]),
                        "destination": .object([
                            "type": .string("string"),
                            "description": .string("New relative path (e.g. notes/projects/machine-learning.md)")
                        ])
                    ]),
                    "required": .array([.string("source"), .string("destination")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "move_notes",
                description: "Batch move/rename up to 20 notes in a single atomic operation. Validates ALL moves before executing any — if any is invalid, nothing changes. Rolls back on partial failure. Use this instead of multiple move_note calls when reorganizing. Single git commit for the batch.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "moves": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "source": .object([
                                        "type": .string("string"),
                                        "description": .string("Current relative path")
                                    ]),
                                    "destination": .object([
                                        "type": .string("string"),
                                        "description": .string("New relative path")
                                    ])
                                ]),
                                "required": .array([.string("source"), .string("destination")])
                            ]),
                            "description": .string("Array of {source, destination} pairs. Maximum 20 moves per call.")
                        ])
                    ]),
                    "required": .array([.string("moves")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "delete_note",
                description: "Soft-delete a note by moving it to .trash/ — the file is NOT permanently deleted and can be recovered. Git auto-commits the deletion.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ])
                    ]),
                    "required": .array([.string("path")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "create_canvas",
                description: "Create a new Obsidian canvas (.canvas) file. Path must start with \"notes/\", end in .canvas, and must not already exist. Content must be valid JSON Canvas 1.0 (an object with \"nodes\" and/or \"edges\" arrays). Creates parent directories automatically. Git auto-commits.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path for the new file (e.g. notes/boards/roadmap.canvas)")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("JSON Canvas 1.0 content. Nodes have id/type/x/y/width/height (type: text|file|link|group); edges have id/fromNode/toNode.")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("content")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ))

            tools.append(Tool(
                name: "update_canvas",
                description: "Replace the ENTIRE contents of an existing canvas (.canvas) file. Content must be valid JSON Canvas 1.0. Read the canvas first with read_canvas, then send the full updated JSON. Git auto-commits.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the .canvas file")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("Full replacement JSON Canvas 1.0 content")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("content")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ))

            tools.append(Tool(
                name: "delete_canvas",
                description: "Soft-delete a canvas (.canvas) file by moving it to .trash/ — recoverable, not permanently deleted. Git auto-commits the deletion.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the .canvas file")
                        ])
                    ]),
                    "required": .array([.string("path")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ))

            tools.append(Tool(
                name: "delete_attachment",
                description: "Soft-delete a binary attachment — ANY file under notes/ that isn't a note (.md) or canvas (.canvas): images, PDFs, CSVs, etc. — by moving it to .trash/. Recoverable, not permanently deleted. Pass the attachment's vault path (get it from list_attachments). For notes use delete_note; for canvases use delete_canvas. Git auto-commits the deletion.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the attachment, e.g. notes/apple/_attachments/bug-repro.png (from list_attachments)")
                        ])
                    ]),
                    "required": .array([.string("path")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ))

            tools.append(Tool(
                name: "add_image",
                description: "Import an image from a path on disk into the vault. Pass the source file path (e.g. a screenshot or test artifact you produced) and a destination under \"notes/\" (e.g. notes/apple/_attachments/bug-repro.png). The file is validated as a real image and re-encoded to a clean PNG — only pixels are kept, so EXIF, trailing bytes, and any non-image payload are stripped; a file that isn't a decodable image is rejected. The destination extension is normalized to .png and must not already exist. The source file is only read, never modified or removed — clean up the original yourself if needed. Useful for filing bug-repro or test-validation screenshots. Git auto-commits. After importing, use the returned path with read_image or embed it in a note.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Path on disk to the source image (absolute path recommended). Must be a real, decodable image. Read only — never modified.")
                        ]),
                        "destination": .object([
                            "type": .string("string"),
                            "description": .string("Vault destination under notes/ (e.g. notes/apple/_attachments/bug-repro.png). Stored as PNG; the extension is normalized to .png.")
                        ])
                    ]),
                    "required": .array([.string("source"), .string("destination")])
                ]),
                // Purely additive: creates a new vault file (reject-if-exists), never deletes anything.
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ))
        }

        // -- Git history tools (only if not read-only) -- Phase 4
        if !config.readOnly {
            tools.append(Tool(
                name: "note_history",
                description: "Show git commit history for a specific note. Use this to find a commit hash for revert_note, or to review what changed and when. For vault-wide history, use vault_changelog instead.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ]),
                        "max_entries": .object([
                            "type": .string("integer"),
                            "description": .string("Limit history entries (default: 10)")
                        ])
                    ]),
                    "required": .array([.string("path")])
                ]),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "revert_note",
                description: "Revert a note to a previous version. Requires a commit hash — call note_history first to find it. Creates a NEW commit (does not rewrite history), so the current version is preserved in git.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Relative path to the note")
                        ]),
                        "commit": .object([
                            "type": .string("string"),
                            "description": .string("Commit hash to revert to (get this from note_history)")
                        ])
                    ]),
                    "required": .array([.string("path"), .string("commit")])
                ]),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ))

            tools.append(Tool(
                name: "vault_changelog",
                description: "Show recent changes across ALL notes in the vault. Use this to answer \"what changed recently?\" questions. For history of one specific note, use note_history instead.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "max_entries": .object([
                            "type": .string("integer"),
                            "description": .string("Limit entries (default: 20)")
                        ]),
                        "since": .object([
                            "type": .string("string"),
                            "description": .string("Show changes from this date forward (ISO format, e.g. 2026-03-01)")
                        ])
                    ])
                ]),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ))
        }

        // -- Reference tools (always read-only) -- Phase 5
        tools.append(Tool(
            name: "list_references",
            description: "List all PDFs in the reference library with title, author, page count, and file size. Use this to browse available books or find a PDF's exact path for read_reference. Filter by subdirectory (e.g. \"Papers\", \"Kodeco\") to narrow results.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object([
                        "type": .string("string"),
                        "description": .string("Subdirectory within references/ (default: all)")
                    ])
                ])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "read_reference",
            description: """
                Read PDF pages as extracted text + JPEG images — text for accurate \
                reading, images for diagrams/figures/equations. Also returns the PDF \
                outline (table of contents) and page labels on every call — use the \
                outline to navigate to specific chapters. Navigation: 'page' for a \
                specific page, 'book_page' for printed page numbers (e.g. "42", "xii"), \
                'page_range' for a range, 'query' to search within THIS specific PDF \
                (searches full document text, unlike search_references which only covers \
                cached pages). Default: first 5 pages. Max: 20 pages per call.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Relative path to PDF (e.g. references/book.pdf)")]),
                    "page": .object(["type": .string("integer"), "description": .string("PDF page number (1-indexed, physical page in the PDF file)")]),
                    "book_page": .object(["type": .string("string"), "description": .string("Navigate by printed page number (e.g. '42', 'xii'). Uses page labels embedded in the PDF.")]),
                    "page_range": .object(["type": .string("string"), "description": .string("Page range like '10-25'")]),
                    "query": .object(["type": .string("string"), "description": .string("Search within the PDF for text, returns matching pages as images")]),
                    "max_pages": .object(["type": .string("integer"), "description": .string("Max pages to return (default: 5, hard cap: 20). For longer sections, make multiple calls with page_range.")])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "search_references",
            description: """
                Keyword search across ALL PDFs in the library. Returns matching books \
                with page numbers and snippets. IMPORTANT: for books over 200 pages, \
                only the first 30 pages and chapter titles are indexed here. If you \
                suspect content is deeper in a specific book, use read_reference with \
                the 'query' parameter instead — it searches the FULL text of that PDF. \
                Results are capped per book (default 3) to show breadth across the \
                library.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search terms (literal keyword match, case-insensitive)")]),
                    "max_results": .object(["type": .string("integer"), "description": .string("Limit results (default: 10)")]),
                    "max_per_document": .object(["type": .string("integer"), "description": .string("Max results per PDF (default: 3). Set higher to see more pages from each book.")])
                ]),
                "required": .array([.string("query")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        tools.append(Tool(
            name: "get_reference_metadata",
            description: "Get PDF metadata (title, author, subject, page count, file size, creation date) without reading any pages. Also reports whether book_page navigation is available. Use this to check a book's details before deciding which pages to read.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Relative path to the PDF")])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        // -- Image tool (always read-only) --
        tools.append(Tool(
            name: "read_image",
            description: """
                Read an image and return it for viewing, with its dimensions and format. \
                Supports png, jpg/jpeg, gif, webp, heic/heif, tiff, bmp (not SVG). Stills \
                within the model's native resolution are returned as-is; oversized ones are \
                downscaled. An ANIMATED GIF is returned as a bundle of sampled PNG frames \
                (read them in order as a time sequence) since the model can't perceive GIF \
                motion from a single image. Use list_attachments to find images. The path \
                must be within notes/ or references/.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path to an image file (e.g. notes/attachments/screenshot.png)")
                    ])
                ]),
                "required": .array([.string("path")])
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ))

        return tools
    }

    // MARK: - Tool Dispatch

    private static func handleToolCall(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        referenceManager: ReferenceManager,
        searchEngine: SearchEngine,
        gitManager: GitManager?,
        config: ServerConfig,
        auditLogger: AuditLogger,
        imageManager: ImageManager,
        canvasManager: CanvasManager,
        attachmentManager: AttachmentManager,
        linkResolver: LinkResolver,
        imageImporter: ImageImporter
    ) async throws -> CallTool.Result {
        // Note: searchEngine is a value type (struct), passed through for search handlers.
        // Audit log every tool call
        let auditOp: AuditLogger.Operation? = switch params.name {
        case "read_note": .read
        case "read_notes": .read
        case "list_notes": .read
        case "get_note_metadata": .read
        case "search_notes": .search
        case "create_note": .create
        case "update_note": .update
        case "move_note": .move
        case "move_notes": .move
        case "delete_note": .delete
        case "note_history": .read
        case "revert_note": .update
        case "vault_changelog": .read
        case "list_references": .listRef
        case "read_reference": .readRef
        case "search_references": .searchRef
        case "get_reference_metadata": .metadataRef
        case "read_image": .read
        case "read_canvas": .read
        case "list_canvas": .read
        case "search_canvas": .search
        case "list_attachments": .read
        case "resolve_link": .read
        case "find_backlinks": .read
        case "create_canvas": .create
        case "update_canvas": .update
        case "delete_canvas": .delete
        case "delete_attachment": .delete
        case "add_image": .create
        default: nil
        }
        if let op = auditOp {
            let path = params.arguments?["path"]?.stringValue
            await auditLogger.log(operation: op, path: path, details: params.name)
        }

        // Enforce --read-only at dispatch, not just by hiding tools from ListTools:
        // the MCP protocol lets a client call any tool by name, so a write tool that
        // was omitted from the list would otherwise still execute here. The attempt
        // is audited above before being rejected.
        if config.readOnly, auditOp?.isWrite == true {
            return CallTool.Result(
                content: [.text(text: "Server is running in read-only mode; '\(params.name)' is not permitted.", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        switch params.name {
        // Note tools
        case "read_note":
            return try await handleReadNote(params: params, vaultManager: vaultManager)
        case "read_notes":
            return try await handleReadNotes(params: params, vaultManager: vaultManager)
        case "list_notes":
            return try await handleListNotes(params: params, vaultManager: vaultManager)
        case "get_note_metadata":
            return try await handleGetNoteMetadata(params: params, vaultManager: vaultManager)
        case "search_notes":
            return handleSearchNotes(params: params, searchEngine: searchEngine)
        case "create_note":
            return try await handleCreateNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        case "update_note":
            return try await handleUpdateNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        case "move_note":
            return try await handleMoveNote(params: params, vaultManager: vaultManager, gitManager: gitManager, auditLogger: auditLogger)
        case "move_notes":
            return try await handleMoveNotes(params: params, vaultManager: vaultManager, gitManager: gitManager, auditLogger: auditLogger)
        case "delete_note":
            return try await handleDeleteNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        // Git tools
        case "note_history":
            return await handleNoteHistory(params: params, gitManager: gitManager)
        case "revert_note":
            return try await handleRevertNote(params: params, vaultManager: vaultManager, gitManager: gitManager)
        case "vault_changelog":
            return await handleVaultChangelog(params: params, gitManager: gitManager)
        // Reference tools
        case "list_references":
            return handleListReferences(params: params, referenceManager: referenceManager)
        case "read_reference":
            return await handleReadReference(params: params, referenceManager: referenceManager)
        case "search_references":
            return handleSearchReferences(params: params, searchEngine: searchEngine)
        case "get_reference_metadata":
            return handleGetReferenceMetadata(params: params, referenceManager: referenceManager)
        // Image tools
        case "read_image":
            return await handleReadImage(params: params, imageManager: imageManager)
        // Canvas tools
        case "read_canvas":
            return await handleReadCanvas(params: params, canvasManager: canvasManager)
        case "list_canvas":
            return await handleListCanvas(params: params, canvasManager: canvasManager)
        case "search_canvas":
            return await handleSearchCanvas(params: params, canvasManager: canvasManager)
        case "list_attachments":
            return await handleListAttachments(params: params, attachmentManager: attachmentManager)
        case "resolve_link":
            return await handleResolveLink(params: params, linkResolver: linkResolver)
        case "find_backlinks":
            return await handleFindBacklinks(params: params, linkResolver: linkResolver)
        case "create_canvas":
            return await handleCreateCanvas(params: params, canvasManager: canvasManager, gitManager: gitManager)
        case "update_canvas":
            return await handleUpdateCanvas(params: params, canvasManager: canvasManager, gitManager: gitManager)
        case "delete_canvas":
            return await handleDeleteCanvas(params: params, canvasManager: canvasManager, gitManager: gitManager)
        case "delete_attachment":
            return await handleDeleteAttachment(params: params, attachmentManager: attachmentManager, gitManager: gitManager)
        case "add_image":
            return await handleAddImage(params: params, imageImporter: imageImporter, gitManager: gitManager)
        default:
            return CallTool.Result(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - Tool Handlers

    private static func handleReadNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let note = try await vaultManager.readNote(relativePath: path)
            return CallTool.Result(
                content: [.text(text: note.content, annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private static func handleReadNotes(
        params: CallTool.Parameters,
        vaultManager: VaultManager
    ) async throws -> CallTool.Result {
        guard let pathValues = params.arguments?["paths"]?.arrayValue, !pathValues.isEmpty else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameter: paths (non-empty array of strings)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let allPaths = pathValues.compactMap(\.stringValue)
        guard !allPaths.isEmpty else {
            return CallTool.Result(
                content: [.text(text: "paths must contain at least one string", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let maxNotes = 20
        let pathsToRead = Array(allPaths.prefix(maxNotes))
        let skippedPaths = allPaths.count > maxNotes ? Array(allPaths.suffix(from: maxNotes)) : []

        // First pass: read all notes, collecting results and metadata for the index
        struct NoteResult {
            let path: String
            let title: String
            let wordCount: Int
            let content: String
            let error: String?
        }

        var results: [NoteResult] = []

        for path in pathsToRead {
            do {
                let note = try await vaultManager.readNote(relativePath: path)
                let wordCount = note.metadata.bodyContent
                    .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                    .count
                results.append(NoteResult(
                    path: path,
                    title: note.metadata.title,
                    wordCount: wordCount,
                    content: note.content,
                    error: nil
                ))
            } catch {
                results.append(NoteResult(
                    path: path,
                    title: "",
                    wordCount: 0,
                    content: "",
                    error: "\(error)"
                ))
            }
        }

        let successCount = results.filter { $0.error == nil }.count

        // Build summary index — lets the LLM triage before reading full content
        var index: [String] = []
        let totalLabel = allPaths.count > maxNotes
            ? "Read \(successCount) of \(allPaths.count) notes:"
            : "Read \(successCount) of \(results.count) notes:"
        index.append(totalLabel)

        for (i, note) in results.enumerated() {
            if let error = note.error {
                index.append("\(i + 1). \(note.path) — ⚠ \(error)")
            } else {
                index.append("\(i + 1). \(note.path) — \"\(note.title)\" (\(note.wordCount) words)")
            }
        }

        if !skippedPaths.isEmpty {
            index.append("")
            index.append("Remaining \(skippedPaths.count) notes not read:")
            for path in skippedPaths {
                index.append("  - \(path)")
            }
        }

        // Build full output: index + content sections
        var output = index.joined(separator: "\n")

        for note in results {
            if let error = note.error {
                output += "\n\n--- \(note.path) ---\n⚠ Error: \(error)"
            } else {
                output += "\n\n--- \(note.path) ---\n\(note.content)"
            }
        }

        return CallTool.Result(
            content: [.text(text: output, annotations: nil, _meta: nil)]
        )
    }

    private static func handleListNotes(
        params: CallTool.Parameters,
        vaultManager: VaultManager
    ) async throws -> CallTool.Result {
        let directory = params.arguments?["directory"]?.stringValue
        let recursive = params.arguments?["recursive"]?.boolValue ?? true
        let tag = params.arguments?["tag"]?.stringValue

        do {
            let notes = try await vaultManager.listNotes(
                directory: directory,
                recursive: recursive,
                tag: tag
            )

            if notes.isEmpty {
                return CallTool.Result(
                    content: [.text(text: "No notes found.", annotations: nil, _meta: nil)]
                )
            }

            let formatter = ISO8601DateFormatter()
            var lines: [String] = ["Found \(notes.count) note(s):", ""]

            for note in notes {
                let dateStr = formatter.string(from: note.modifiedDate)
                let tagStr = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
                lines.append("- **\(note.title)**\(tagStr)")
                lines.append("  Path: `\(note.relativePath)` | Modified: \(dateStr)")
            }

            return CallTool.Result(
                content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private static func handleGetNoteMetadata(
        params: CallTool.Parameters,
        vaultManager: VaultManager
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let meta = try await vaultManager.getNoteMetadata(relativePath: path)
            let formatter = ISO8601DateFormatter()

            var info: [String] = [
                "Title: \(meta.title)",
                "Path: \(meta.relativePath)",
                "Tags: \(meta.tags.isEmpty ? "(none)" : meta.tags.joined(separator: ", "))",
                "Created: \(meta.created ?? "unknown")",
                "Modified: \(formatter.string(from: meta.modifiedDate))",
                "Word count: \(meta.wordCount)"
            ]

            if !meta.links.isEmpty {
                info.append("Links: \(meta.links.joined(separator: ", "))")
            }

            return CallTool.Result(
                content: [.text(text: info.joined(separator: "\n"), annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - Search Handler (Phase 2)

    private static func handleSearchNotes(
        params: CallTool.Parameters,
        searchEngine: SearchEngine
    ) -> CallTool.Result {
        guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameter: query", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let maxResults = params.arguments?["max_results"]?.intValue ?? 20

        let results = searchEngine.searchNotes(
            query: query,
            maxResults: maxResults
        )

        if results.isEmpty {
            return CallTool.Result(content: [.text(text: "No notes found matching '\(query)'.", annotations: nil, _meta: nil)])
        }

        var lines: [String] = ["Found \(results.count) result(s) for '\(query)':", ""]
        for result in results {
            lines.append("- **\(result.title)** (score: \(String(format: "%.2f", result.score)))")
            lines.append("  Path: `\(result.path)`")
            lines.append("  \(result.snippet)")
            lines.append("")
        }

        return CallTool.Result(
            content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)]
        )
    }

    // MARK: - Write Handlers (Phase 3)

    private static func handleCreateNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue,
              let content = params.arguments?["content"]?.stringValue else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameters: path, content", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let tags: [String] = params.arguments?["tags"]?.arrayValue?
            .compactMap(\.stringValue) ?? []

        do {
            let result = try await vaultManager.createNote(relativePath: path, content: content, tags: tags)

            // Git commit
            if let git = gitManager {
                try? await git.commitChange(
                    files: [path],
                    message: "[SecondBrainMCP] Created: \(path)"
                )
            }

            return CallTool.Result(
                content: [.text(text: result, annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private static func handleUpdateNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let mode = params.arguments?["mode"]?.stringValue ?? "replace"

        do {
            if mode == "patch" {
                guard let patchArray = params.arguments?["patches"]?.arrayValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: patches (required for patch mode)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

                var ops: [VaultManager.PatchOperation] = []
                for (index, item) in patchArray.enumerated() {
                    guard let dict = item.objectValue,
                          let oldText = dict["old_text"]?.stringValue,
                          let newText = dict["new_text"]?.stringValue else {
                        return CallTool.Result(
                            content: [.text(text: "Patch at index \(index) missing old_text or new_text", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                    ops.append(VaultManager.PatchOperation(oldText: oldText, newText: newText))
                }

                let result = try await vaultManager.patchNote(relativePath: path, patches: ops)

                if let git = gitManager, !result.hasPrefix("No changes") {
                    try? await git.commitChange(
                        files: [path],
                        message: "[SecondBrainMCP] Updated: \(path) (patch)"
                    )
                }

                return CallTool.Result(
                    content: [.text(text: result, annotations: nil, _meta: nil)]
                )
            } else {
                guard let content = params.arguments?["content"]?.stringValue else {
                    return CallTool.Result(
                        content: [.text(text: "Missing required parameter: content (required for \(mode) mode)", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }

                let result = try await vaultManager.updateNote(relativePath: path, content: content, mode: mode)

                if let git = gitManager {
                    let modeStr = mode == "append" ? " (append)" : ""
                    try? await git.commitChange(
                        files: [path],
                        message: "[SecondBrainMCP] Updated: \(path)\(modeStr)"
                    )
                }

                return CallTool.Result(
                    content: [.text(text: result, annotations: nil, _meta: nil)]
                )
            }
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private static func handleDeleteNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let result = try await vaultManager.deleteNote(relativePath: path)

            // Git commit — use commitDeletion to handle case-insensitive filesystems
            if let git = gitManager {
                try? await git.commitDeletion(
                    path: path,
                    message: "[SecondBrainMCP] Deleted: \(path)"
                )
            }

            return CallTool.Result(
                content: [.text(text: result, annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - Move Handlers

    private static func handleMoveNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?,
        auditLogger: AuditLogger
    ) async throws -> CallTool.Result {
        guard let source = params.arguments?["source"]?.stringValue,
              let destination = params.arguments?["destination"]?.stringValue else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameters: source, destination", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let result = try await vaultManager.moveNote(source: source, destination: destination)

            // Git commit
            if let git = gitManager {
                try? await git.commitMoves(
                    moves: [(source: source, destination: destination)],
                    message: "[SecondBrainMCP] Moved: \(source) to \(destination)"
                )
            }

            await auditLogger.log(operation: .move, path: source, details: "-> \(destination)")

            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private static func handleMoveNotes(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?,
        auditLogger: AuditLogger
    ) async throws -> CallTool.Result {
        guard let movesArray = params.arguments?["moves"]?.arrayValue else {
            return CallTool.Result(
                content: [.text(text: "Missing required parameter: moves (array of {source, destination})", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // Parse the moves array
        var moves: [VaultManager.MoveOperation] = []
        for (index, item) in movesArray.enumerated() {
            guard let source = item.objectValue?["source"]?.stringValue,
                  let destination = item.objectValue?["destination"]?.stringValue else {
                return CallTool.Result(
                    content: [.text(text: "Move at index \(index) missing source or destination", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            moves.append(VaultManager.MoveOperation(source: source, destination: destination))
        }

        do {
            let result = try await vaultManager.moveNotes(moves: moves)

            // Single git commit for the whole batch
            if let git = gitManager {
                let gitMoves = moves.map { (source: $0.source, destination: $0.destination) }
                try? await git.commitMoves(
                    moves: gitMoves,
                    message: "[SecondBrainMCP] Moved \(moves.count) notes"
                )
            }

            for move in moves {
                await auditLogger.log(operation: .move, path: move.source, details: "-> \(move.destination)")
            }

            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - Git History Handlers (Phase 4)

    private static func handleNoteHistory(
        params: CallTool.Parameters,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let git = gitManager else {
            return CallTool.Result(content: [.text(text: "Git not available", annotations: nil, _meta: nil)], isError: true)
        }
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        guard path.hasPrefix("notes/") else {
            return CallTool.Result(content: [.text(text: "Path must be within notes/: \(path)", annotations: nil, _meta: nil)], isError: true)
        }

        let maxEntries = params.arguments?["max_entries"]?.intValue ?? 10

        do {
            let entries = try await git.log(forFile: path, maxEntries: maxEntries)
            if entries.isEmpty {
                return CallTool.Result(content: [.text(text: "No history found for \(path)", annotations: nil, _meta: nil)])
            }

            var lines: [String] = ["History for `\(path)` (\(entries.count) entries):", ""]
            for entry in entries {
                lines.append("- **\(entry.message)**")
                lines.append("  Commit: `\(entry.hash.prefix(8))` | Date: \(entry.date)")
            }

            return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleRevertNote(
        params: CallTool.Parameters,
        vaultManager: VaultManager,
        gitManager: GitManager?
    ) async throws -> CallTool.Result {
        guard let git = gitManager else {
            return CallTool.Result(content: [.text(text: "Git not available", annotations: nil, _meta: nil)], isError: true)
        }
        guard let path = params.arguments?["path"]?.stringValue,
              let commit = params.arguments?["commit"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameters: path, commit", annotations: nil, _meta: nil)], isError: true)
        }

        guard path.hasPrefix("notes/") else {
            return CallTool.Result(content: [.text(text: "Path must be within notes/: \(path)", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            // Checkout the file from the specified commit
            try await git.checkoutFile(path: path, fromCommit: commit)

            // Commit the revert as a new commit
            try await git.commitChange(
                files: [path],
                message: "[SecondBrainMCP] Reverted: \(path) to \(String(commit.prefix(8)))"
            )

            return CallTool.Result(
                content: [.text(text: "Reverted `\(path)` to commit `\(String(commit.prefix(8)))` and created new commit.", annotations: nil, _meta: nil)]
            )
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleVaultChangelog(
        params: CallTool.Parameters,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let git = gitManager else {
            return CallTool.Result(content: [.text(text: "Git not available", annotations: nil, _meta: nil)], isError: true)
        }

        let maxEntries = params.arguments?["max_entries"]?.intValue ?? 20
        let since = params.arguments?["since"]?.stringValue

        do {
            let entries = try await git.log(maxEntries: maxEntries, since: since)
            if entries.isEmpty {
                return CallTool.Result(content: [.text(text: "No changes found.", annotations: nil, _meta: nil)])
            }

            var lines: [String] = ["Vault changelog (\(entries.count) entries):", ""]
            for entry in entries {
                lines.append("- **\(entry.message)**")
                lines.append("  Commit: `\(entry.hash.prefix(8))` | Date: \(entry.date)")
            }

            return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Reference Handlers (Phase 5)

    private static func handleListReferences(
        params: CallTool.Parameters,
        referenceManager: ReferenceManager
    ) -> CallTool.Result {
        let directory = params.arguments?["directory"]?.stringValue

        let refs: [ReferenceManager.ReferenceInfo]
        do {
            refs = try referenceManager.listReferences(directory: directory)
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }

        if refs.isEmpty {
            return CallTool.Result(content: [.text(text: "No PDF references found.", annotations: nil, _meta: nil)])
        }

        var lines: [String] = ["Found \(refs.count) reference(s):", ""]
        for ref in refs {
            let authorStr = ref.author.map { " by \($0)" } ?? ""
            lines.append("- **\(ref.title)**\(authorStr)")
            lines.append("  Path: `\(ref.relativePath)` | Pages: \(ref.pageCount) | Size: \(String(format: "%.1f", ref.fileSizeMB)) MB")
        }

        return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    private static func handleReadReference(
        params: CallTool.Parameters,
        referenceManager: ReferenceManager
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        let page = params.arguments?["page"]?.intValue
        let bookPage = params.arguments?["book_page"]?.stringValue
        let pageRange = params.arguments?["page_range"]?.stringValue
        let query = params.arguments?["query"]?.stringValue
        let maxPages = min(params.arguments?["max_pages"]?.intValue ?? 5, 20)

        do {
            // Timeout protection: corrupt PDFs can hang PDFKit indefinitely.
            // Race the actual work against a 60-second deadline.
            let result = try await withThrowingTaskGroup(of: ReferenceManager.ReferenceContent.self) { group in
                group.addTask {
                    try referenceManager.readReference(
                        relativePath: path,
                        page: page,
                        pageRange: pageRange,
                        bookPage: bookPage,
                        query: query,
                        maxPages: maxPages
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw MCPError.internalError("Timeout: PDF took longer than 60 seconds to process. The file may be corrupt or too large.")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            if result.renderedPages.isEmpty {
                return CallTool.Result(content: [.text(text: "No pages rendered from \(path). The page may not exist.", annotations: nil, _meta: nil)])
            }

            // Build mixed content: text + JPEG images per page
            // Claude uses text for accurate reading, images for diagrams/equations/figures
            var content: [Tool.Content] = []
            content.append(.text(text: "\(result.title) (\(result.totalPages) pages total)", annotations: nil, _meta: nil))

            for p in result.renderedPages {
                let labelInfo = p.bookLabel.map { " (book page: \($0))" } ?? ""
                content.append(.text(text: "--- PDF Page \(p.pageNumber)\(labelInfo) ---", annotations: nil, _meta: nil))

                // Include extracted text first (fast, accurate for Claude to process)
                if let text = p.extractedText {
                    content.append(.text(text: text, annotations: nil, _meta: nil))
                }

                // Always include the image (for diagrams, figures, equations, formatting)
                content.append(.image(data: p.jpegData.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
            }

            // Include PDF outline (bookmarks/TOC) if available — structured chapter navigation
            if let outline = result.outline {
                let indent = ["", "  ", "    "]
                let tocLines = outline.prefix(50).map { entry in
                    let prefix = indent[min(entry.level, 2)]
                    return "\(prefix)- \(entry.title) (page \(entry.pageNumber))"
                }
                let truncated = outline.count > 50 ? "\n  ... (\(outline.count - 50) more entries)" : ""
                content.append(.text(text: "## Table of Contents (from PDF bookmarks)\n" + tocLines.joined(separator: "\n") + truncated, annotations: nil, _meta: nil))
            }

            // Include page label info if available and useful
            if !result.pageLabels.isEmpty {
                let labelSample = result.pageLabels.sorted { $0.key < $1.key }
                    .prefix(5)
                    .map { "PDF page \($0.key) = book page \($0.value)" }
                    .joined(separator: ", ")
                content.append(.text(text: "Page labels: \(labelSample)\(result.pageLabels.count > 5 ? "..." : "")", annotations: nil, _meta: nil))
            }

            return CallTool.Result(content: content)
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleSearchReferences(
        params: CallTool.Parameters,
        searchEngine: SearchEngine
    ) -> CallTool.Result {
        guard let query = params.arguments?["query"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: query", annotations: nil, _meta: nil)], isError: true)
        }

        let maxResults = params.arguments?["max_results"]?.intValue ?? 10
        let maxPerDoc = params.arguments?["max_per_document"]?.intValue ?? 3

        let results = searchEngine.searchReferences(
            query: query,
            maxResults: maxResults,
            maxPerDocument: maxPerDoc
        )

        if results.isEmpty {
            return CallTool.Result(content: [.text(text: "No references found matching '\(query)'.", annotations: nil, _meta: nil)])
        }

        var lines: [String] = ["Found \(results.count) result(s) for '\(query)':", ""]
        for result in results {
            let pageStr = result.pageNumber.map { " -- Page \($0)" } ?? ""
            lines.append("- **\(result.title)**\(pageStr) (score: \(String(format: "%.2f", result.score)))")
            lines.append("  Path: `\(result.path)`")
            lines.append("  \(result.snippet)")
            lines.append("")
        }

        return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    private static func handleGetReferenceMetadata(
        params: CallTool.Parameters,
        referenceManager: ReferenceManager
    ) -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let meta = try referenceManager.getMetadata(relativePath: path)
            let formatter = ISO8601DateFormatter()

            let info: [String] = [
                "Title: \(meta.title ?? "Unknown")",
                "Author: \(meta.author ?? "Unknown")",
                "Subject: \(meta.subject ?? "N/A")",
                "Pages: \(meta.pageCount)",
                "Size: \(String(format: "%.1f", meta.fileSizeMB)) MB",
                "Created: \(meta.creationDate.map { formatter.string(from: $0) } ?? "Unknown")",
                "Page labels: \(meta.hasPageLabels ? "Yes (book page numbers available via book_page parameter)" : "No")"
            ]

            return CallTool.Result(content: [.text(text: info.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Image Handler

    private static func handleReadImage(
        params: CallTool.Parameters,
        imageManager: ImageManager
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            // Timeout protection: a crafted image could hang the decoder. Race the
            // work against a deadline, same pattern as handleReadReference.
            let result = try await withThrowingTaskGroup(of: ImageManager.ImageResult.self) { group in
                group.addTask { try imageManager.read(relativePath: path) }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw MCPError.internalError("Timeout: image took longer than 30 seconds to process. The file may be corrupt.")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            let sizeStr = formatBytes(result.originalBytes)
            var content: [Tool.Content] = []

            if result.totalFrames > 1 {
                // Animated GIF → time-ordered frame bundle.
                let indices = result.frames.map { String($0.sourceIndex) }.joined(separator: ", ")
                let durationStr = result.totalDurationSeconds.map { String(format: ", ~%.1fs long", $0) } ?? ""
                content.append(.text(text:
                    "Animated GIF \(result.originalWidth)×\(result.originalHeight), \(sizeStr), \(result.totalFrames) frames total\(durationStr). "
                    + "Showing \(result.frames.count) frames sampled across the animation (source indices: \(indices)) as PNGs — "
                    + "read them in order as a time sequence; each frame is labeled with its time offset from the start.",
                    annotations: nil, _meta: nil))
                for (i, frame) in result.frames.enumerated() {
                    let timeStr = frame.timeOffsetSeconds.map { String(format: " at t≈%.2fs", $0) } ?? ""
                    content.append(.text(text: "Frame \(i + 1) of \(result.frames.count) (source frame \(frame.sourceIndex)\(timeStr)):", annotations: nil, _meta: nil))
                    content.append(.image(data: frame.data.base64EncodedString(), mimeType: frame.mimeType, annotations: nil, _meta: nil))
                }
            } else {
                let note = result.passedThrough ? "passed through unchanged" : "downscaled / re-encoded to PNG"
                content.append(.text(text: "\(result.format.uppercased()) \(result.originalWidth)×\(result.originalHeight), \(sizeStr) — \(note)", annotations: nil, _meta: nil))
                if let frame = result.frames.first {
                    content.append(.image(data: frame.data.base64EncodedString(), mimeType: frame.mimeType, annotations: nil, _meta: nil))
                }
            }

            return CallTool.Result(content: content)
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Canvas Handlers

    private static func handleReadCanvas(
        params: CallTool.Parameters,
        canvasManager: CanvasManager
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let summary = try await canvasManager.read(relativePath: path)
            var lines = ["\(summary.relativePath): \(summary.nodeCount) node(s), \(summary.edgeCount) edge(s)"]
            for node in summary.nodes {
                let label = node.label.isEmpty ? "" : " — \(node.label)"
                let warn = node.warning.map { " ⚠ \($0)" } ?? ""
                lines.append("  - [\(node.type)] \(node.id)\(label)\(warn)")
            }
            let header = lines.joined(separator: "\n")
            return CallTool.Result(content: [.text(text: "\(header)\n\n\(summary.rawJSON)", annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleListAttachments(
        params: CallTool.Parameters,
        attachmentManager: AttachmentManager
    ) async -> CallTool.Result {
        let directory = params.arguments?["directory"]?.stringValue
        let recursive = params.arguments?["recursive"]?.boolValue ?? true

        do {
            let items = try await attachmentManager.list(directory: directory, recursive: recursive)
            if items.isEmpty {
                return CallTool.Result(content: [.text(text: "No attachments found.", annotations: nil, _meta: nil)])
            }

            var lines: [String] = [
                "Found \(items.count) attachment(s) — `readable` = openable with read_image:",
                ""
            ]
            for item in items {
                let extStr = item.ext.isEmpty ? "(no ext)" : item.ext
                let readableStr = item.readable ? "readable" : "unreadable"
                lines.append("- `\(item.relativePath)` — \(extStr) · \(formatBytes(item.sizeBytes)) · \(readableStr)")
            }
            return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Link Handlers (Tier 2)

    private static func handleResolveLink(
        params: CallTool.Parameters,
        linkResolver: LinkResolver
    ) async -> CallTool.Result {
        guard let link = params.arguments?["link"]?.stringValue, !link.isEmpty else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: link", annotations: nil, _meta: nil)], isError: true)
        }
        let from = params.arguments?["from"]?.stringValue

        do {
            let r = try linkResolver.resolve(link: link, from: from)
            let kind = r.isEmbed ? "embed" : "link"
            if r.matches.isEmpty {
                return CallTool.Result(content: [.text(text: "No vault file resolves \(kind) '\(r.target)'.", annotations: nil, _meta: nil)])
            }
            if r.matches.count == 1 {
                return CallTool.Result(content: [.text(text: "\(kind) '\(r.target)' → `\(r.matches[0])`", annotations: nil, _meta: nil)])
            }
            var lines = ["\(kind) '\(r.target)' is ambiguous — \(r.matches.count) candidates (best match first):"]
            for path in r.matches { lines.append("  - `\(path)`") }
            return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleFindBacklinks(
        params: CallTool.Parameters,
        linkResolver: LinkResolver
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue, !path.isEmpty else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let backlinks = try linkResolver.backlinks(to: path)
            if backlinks.isEmpty {
                return CallTool.Result(content: [.text(text: "No notes reference '\(path)'.", annotations: nil, _meta: nil)])
            }
            var lines = ["\(backlinks.count) note(s) reference '\(path)':", ""]
            for b in backlinks {
                lines.append("- `\(b.notePath)` \(b.isEmbed ? "(embed)" : "(link)"): \(b.raw)")
            }
            return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    private static func handleListCanvas(
        params: CallTool.Parameters,
        canvasManager: CanvasManager
    ) async -> CallTool.Result {
        let directory = params.arguments?["directory"]?.stringValue
        let recursive = params.arguments?["recursive"]?.boolValue ?? true

        do {
            let canvases = try await canvasManager.listCanvases(directory: directory, recursive: recursive)
            if canvases.isEmpty {
                return CallTool.Result(content: [.text(text: "No canvases found.", annotations: nil, _meta: nil)])
            }

            let formatter = ISO8601DateFormatter()
            var lines: [String] = ["Found \(canvases.count) canvas(es):", ""]
            for canvas in canvases {
                let breakdown = canvas.typeBreakdown.map { "\($0.count) \($0.type)" }.joined(separator: ", ")
                let breakdownStr = breakdown.isEmpty ? "" : " [\(breakdown)]"
                lines.append("- `\(canvas.relativePath)` — \(canvas.nodeCount) node(s), \(canvas.edgeCount) edge(s)\(breakdownStr)")
                lines.append("  Modified: \(formatter.string(from: canvas.modifiedDate))")
            }
            return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleSearchCanvas(
        params: CallTool.Parameters,
        canvasManager: CanvasManager
    ) async -> CallTool.Result {
        guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: query", annotations: nil, _meta: nil)], isError: true)
        }
        let maxResults = params.arguments?["max_results"]?.intValue ?? 20

        do {
            let results = try await canvasManager.search(query: query, maxResults: maxResults)
            if results.hits.isEmpty {
                return CallTool.Result(content: [.text(text: "No canvas nodes found matching '\(query)'.", annotations: nil, _meta: nil)])
            }

            let header = results.totalMatches > results.hits.count
                ? "Found \(results.totalMatches) match(es) for '\(query)' (showing first \(results.hits.count)):"
                : "Found \(results.hits.count) match(es) for '\(query)':"
            var lines: [String] = [header, ""]
            var currentPath: String? = nil
            for hit in results.hits {
                if hit.relativePath != currentPath {
                    lines.append("`\(hit.relativePath)`")
                    currentPath = hit.relativePath
                }
                lines.append("  - [\(hit.nodeType)] \(hit.nodeID) (\(hit.field)): \(hit.snippet)")
            }
            return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleCreateCanvas(
        params: CallTool.Parameters,
        canvasManager: CanvasManager,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue,
              let content = params.arguments?["content"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameters: path, content", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let result = try await canvasManager.create(relativePath: path, json: content)
            if let git = gitManager {
                try? await git.commitChange(files: [path], message: "[SecondBrainMCP] Created: \(path)")
            }
            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleUpdateCanvas(
        params: CallTool.Parameters,
        canvasManager: CanvasManager,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue,
              let content = params.arguments?["content"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameters: path, content", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let result = try await canvasManager.replace(relativePath: path, json: content)
            if let git = gitManager {
                try? await git.commitChange(files: [path], message: "[SecondBrainMCP] Updated: \(path)")
            }
            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleDeleteCanvas(
        params: CallTool.Parameters,
        canvasManager: CanvasManager,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let result = try await canvasManager.delete(relativePath: path)
            if let git = gitManager {
                try? await git.commitDeletion(path: path, message: "[SecondBrainMCP] Deleted: \(path)")
            }
            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func handleDeleteAttachment(
        params: CallTool.Parameters,
        attachmentManager: AttachmentManager,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let path = params.arguments?["path"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "Missing required parameter: path", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            let result = try await attachmentManager.delete(relativePath: path)
            if let git = gitManager {
                try? await git.commitDeletion(path: path, message: "[SecondBrainMCP] Deleted: \(path)")
            }
            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Image Import Handler

    private static func handleAddImage(
        params: CallTool.Parameters,
        imageImporter: ImageImporter,
        gitManager: GitManager?
    ) async -> CallTool.Result {
        guard let source = params.arguments?["source"]?.stringValue, !source.isEmpty,
              let destination = params.arguments?["destination"]?.stringValue, !destination.isEmpty else {
            return CallTool.Result(content: [.text(text: "Missing required parameters: source, destination", annotations: nil, _meta: nil)], isError: true)
        }

        do {
            // Timeout protection: a crafted/corrupt source could hang the decoder.
            // Race the work against a deadline, same pattern as handleReadImage.
            let r = try await withThrowingTaskGroup(of: ImageImporter.ImportResult.self) { group in
                group.addTask { try await imageImporter.add(source: source, destination: destination) }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw MCPError.internalError("Timeout: image import took longer than 30 seconds to process. The source may be corrupt.")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            if let git = gitManager {
                try? await git.commitChange(files: [r.destination], message: "[SecondBrainMCP] Added image: \(r.destination)")
            }
            var msg = "Added image → `\(r.destination)` (\(r.sourceFormat.uppercased()) \(r.width)×\(r.height) re-encoded to PNG, \(formatBytes(r.bytesWritten)))"
            if let note = r.note { msg += "\n⚠ \(note)" }
            return CallTool.Result(content: [.text(text: msg, annotations: nil, _meta: nil)])
        } catch {
            return CallTool.Result(content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Resource Handlers (Phase 6)

    private static func handleIndexResource(
        vaultManager: VaultManager
    ) async throws -> ReadResource.Result {
        let notes = (try? await vaultManager.listNotes()) ?? []

        let entries: [[String: Any]] = notes.map { note in
            var entry: [String: Any] = [
                "path": note.relativePath,
                "title": note.title
            ]
            if !note.tags.isEmpty {
                entry["tags"] = note.tags
            }
            return entry
        }

        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://index", mimeType: "application/json")
        ])
    }

    private static func handleRecentResource(
        vaultManager: VaultManager
    ) async throws -> ReadResource.Result {
        let notes = (try? await vaultManager.listNotes()) ?? []
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        let recent = notes.filter { $0.modifiedDate >= sevenDaysAgo }

        let formatter = ISO8601DateFormatter()
        let entries: [[String: Any]] = recent.map { note in
            [
                "path": note.relativePath,
                "title": note.title,
                "modified": formatter.string(from: note.modifiedDate)
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://recent", mimeType: "application/json")
        ])
    }

    private static func handleTagsResource(
        vaultManager: VaultManager
    ) async throws -> ReadResource.Result {
        let notes = (try? await vaultManager.listNotes()) ?? []

        var tagCounts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags {
                tagCounts[tag, default: 0] += 1
            }
        }

        let data = try JSONSerialization.data(withJSONObject: tagCounts, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "{}"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://tags", mimeType: "application/json")
        ])
    }

    private static func handleReferencesResource(
        referenceManager: ReferenceManager
    ) -> ReadResource.Result {
        let refs = (try? referenceManager.listReferences()) ?? []

        let entries: [[String: Any]] = refs.map { ref in
            var entry: [String: Any] = [
                "path": ref.relativePath,
                "title": ref.title,
                "pages": ref.pageCount,
                "sizeMB": ref.fileSizeMB
            ]
            if let author = ref.author {
                entry["author"] = author
            }
            return entry
        }

        let data = (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return ReadResource.Result(contents: [
            .text(json, uri: "secondbrain://references", mimeType: "application/json")
        ])
    }
}
