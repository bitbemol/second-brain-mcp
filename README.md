# SecondBrainMCP

A local MCP server in Swift that gives Claude Desktop read/write access to a Markdown note vault and read-only access to a PDF reference library. Every note edit is automatically committed to git.

```
Claude Desktop  ─┐
                 ├── stdio ──> SecondBrainMCP
Claude Code CLI ─┘                |
                                  +── notes/       (Markdown, read/write, git tracked)
                                  +── references/  (PDFs, read-only)
```

> **Important:** MCP servers only work with **Claude Desktop** (the macOS app) and **Claude Code** (the CLI). They do **not** work with claude.ai in the browser.

## Features

- **17 MCP tools** — search, read (single & batch), create, update, move, delete notes; search and read PDFs; git history and revert
- **4 MCP resources** — vault index, recent notes, tags summary, references index
- **Git auto-commit** — every write creates a commit with `[SecondBrainMCP]` prefix
- **Soft deletes** — deleted notes move to `.trash/`, never permanently removed
- **Full-text search** — disk-based grep across notes and PDF search cache
- **Image-based PDF reading** — dual content per page (extracted text + JPEG image), book page navigation, PDF outline/bookmarks
- **Read-only mode** — `--read-only` flag hides all write tools
- **Path security** — symlink resolution, traversal prevention, extension allowlists
- **Audit log** — every operation logged to `.secondbrain-mcp/audit.log`
- **Works alongside Obsidian, iA Writer, Logseq** — the vault is plain Markdown; app config directories are ignored
- **Custom instructions** — drop an `INSTRUCTIONS.md` in your vault root to define your own conventions

## Quick Start

```bash
# 1. Build
swift build -c release
# Binary is at .build/release/second-brain-mcp

# 2. Create a vault
./setup-vault.sh

# 3. Connect to Claude Desktop or Claude Code (see below)

# 4. Ask Claude: "What notes do I have?"
```

## Requirements

- Swift 6.2 or later (builds on 6.4 — note the [build-output path change](#installation) on 6.4+)
- macOS 26 (Tahoe) or later
- Xcode 26 or later

## Installation

```bash
git clone https://github.com/yourusername/SecondBrainMCP.git
cd SecondBrainMCP
swift build -c release
```

The binary is at `.build/release/second-brain-mcp`. You can copy it anywhere:

```bash
cp .build/release/second-brain-mcp /usr/local/bin/
```

> **Always use the `.build/release/second-brain-mcp` path — not an architecture-specific one** like `.build/arm64-apple-macosx/release/second-brain-mcp`. Swift 6.4 changed SwiftPM's default build system from `native` (which wrote products to `.build/<triple>/release/`) to `swiftbuild` (which writes to `.build/out/Products/Release/`). SwiftPM keeps `.build/release` and `.build/debug` as symlinks to the current layout under **both** systems, so pinning to the symlink survives toolchain upgrades. Pinning to an arch-specific path will silently keep launching a **stale binary** after you upgrade Swift — the build succeeds, but lands somewhere your config no longer points to.

## Connecting to Claude

SecondBrainMCP works with **Claude Desktop** (the macOS app) and **Claude Code** (the CLI). It does **not** work with claude.ai in the browser.

### Option A: Claude Desktop (the macOS app)

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "second-brain": {
      "command": "/absolute/path/to/.build/release/second-brain-mcp",
      "args": ["--vault", "/absolute/path/to/your/vault"]
    }
  }
}
```

**Restart Claude Desktop after saving** (Cmd+Q, then reopen). The server starts automatically when Claude needs it. Verify by asking Claude *"What tools do you have?"* — you should see the SecondBrainMCP tools.

### Option B: Claude Code (the CLI)

```bash
claude mcp add second-brain -- \
  /absolute/path/to/.build/release/second-brain-mcp \
  --vault /absolute/path/to/your/vault
```

This registers the server globally. It's available immediately in new `claude` sessions — no restart needed.

To scope it to a specific project instead, use `-s project`:

```bash
claude mcp add -s project second-brain -- \
  /absolute/path/to/.build/release/second-brain-mcp \
  --vault /absolute/path/to/your/vault
```

You can also import your Claude Desktop config directly:

```bash
claude mcp add-from-claude-desktop
```

Verify with:
```bash
claude mcp list
```

### Updating the server

After pulling changes or editing the code, rebuild and **relaunch the client** so new or changed tools are picked up:

```bash
swift build -c release
```

Then fully restart: **Cmd+Q and reopen Claude Desktop**, or start a new `claude` session. A running server keeps serving its old tool list until the process is relaunched — rebuilding alone isn't enough.

If new tools still don't appear, confirm the client's `command` points at `.build/release/second-brain-mcp` (the symlink, see [Installation](#installation)) and not a stale architecture-specific path.

### What does NOT work

- **claude.ai** (the website) — does not support MCP servers
- **Claude mobile apps** — do not support MCP servers
- Any Claude interface that isn't Claude Desktop or Claude Code

## Vault Structure

```
~/SecondBrain/
├── notes/              <- Your Markdown notes (editable, git tracked)
│   ├── projects/
│   ├── journal/
│   └── ideas/
├── references/         <- PDF books and papers (read-only)
├── INSTRUCTIONS.md     <- Optional: custom rules for the AI (see below)
├── .git/               <- Auto-created on first run
├── .trash/             <- Soft-deleted notes land here
└── .secondbrain-mcp/   <- Audit log + lightweight search cache
```

Only `notes/` and `references/` need to exist. Everything else is auto-created on first startup.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--vault <path>` | *(required)* | Path to your vault directory |
| `--read-only` | `false` | Disable all write/delete/revert tools |
| `--extensions <list>` | `md,markdown` | Allowed note file extensions |
| `--log-level <level>` | `info` | `debug`, `info`, `warning`, `error` |

## Tools

### Notes

| Tool | Description |
|------|-------------|
| `read_note` | Read a note's full content |
| `read_notes` | Read up to 20 notes in one call, with summary index and per-note error reporting |
| `list_notes` | List notes, filter by directory or tag |
| `get_note_metadata` | Title, tags, word count, links |
| `search_notes` | Full-text grep search across all notes |
| `create_note` | Create with auto-generated frontmatter |
| `update_note` | Replace or append mode |
| `move_note` | Move/rename a note within notes/, preserves git history |
| `move_notes` | Batch move up to 20 notes atomically (all-or-nothing) |
| `delete_note` | Soft-delete to `.trash/` |

### Canvas

Obsidian [JSON Canvas](https://jsoncanvas.org) (`.canvas`) files, stored under `notes/`. Writes validate against the JSON Canvas 1.0 spec, then persist your original bytes (so plugin-added keys survive).

| Tool | Description |
|------|-------------|
| `list_canvas` | List canvases with node/edge counts and a per-type breakdown (metadata only) |
| `read_canvas` | Node/edge summary + raw JSON |
| `create_canvas` | Create a validated `.canvas` file |
| `update_canvas` | Replace an existing canvas's full contents (validated) |
| `delete_canvas` | Soft-delete to `.trash/` |

`read_canvas` flags `file`-nodes whose target doesn't exist with `⚠ file not found`. These are **not** rejected on write: unlike edge→node references (validated for structural integrity), a `file`-node→file reference is a soft link the JSON Canvas spec and Obsidian both tolerate (forward references, files added later).

### Images & attachments

| Tool | Description |
|------|-------------|
| `list_attachments` | List binary attachments under `notes/` (anything that isn't a `.md` note or `.canvas`) — path, extension, size, and whether `read_image` can open it. Closes the image-discovery gap that `list_notes` leaves. |
| `read_image` | Read an image (png/jpg/jpeg/gif/webp/heic/heif/tiff/bmp) from `notes/` or `references/` for viewing. Within-cap stills pass through unchanged, oversized ones are downscaled. **Animated GIFs** come back as a bundle of sampled PNG frames so the model can read them as a time sequence. |

### References (read-only)

| Tool | Description |
|------|-------------|
| `list_references` | List all PDFs with metadata |
| `read_reference` | Read pages as text + JPEG images, with page/range/query/book_page modes |
| `search_references` | Full-text search across all PDFs |
| `get_reference_metadata` | PDF metadata without reading content |

### Git History

| Tool | Description |
|------|-------------|
| `note_history` | Commit history for a specific note |
| `revert_note` | Revert to a previous version (new commit) |
| `vault_changelog` | Recent changes across the vault |

## Resources

| URI | Description |
|-----|-------------|
| `secondbrain://index` | All notes: paths, titles, tags |
| `secondbrain://recent` | Notes modified in the last 7 days |
| `secondbrain://tags` | All tags with note counts |
| `secondbrain://references` | All PDFs with metadata |

## Custom Instructions

Drop an `INSTRUCTIONS.md` file in your vault root to define conventions the AI should follow when managing your notes. For example:

```markdown
VAULT RULES:
1. Always create notes inside a container directory — never as loose files.
2. Every note must have YAML frontmatter with title, created date, and tags.
3. Ticket notes should start with the ticket ID.
```

The server appends the file contents to its default instructions during startup. If the file doesn't exist, only the built-in defaults are sent. No rebuild required — just create or edit the file and restart the MCP server.

## Security

- **Path traversal prevention** — all paths validated through `PathValidator` with symlink resolution
- **No arbitrary shell execution** — only `/usr/bin/git` and `/usr/bin/grep` with programmatic argument arrays
- **Structural write boundaries** — `ReferenceManager` has zero write methods by design
- **Soft deletes only** — files are never permanently deleted
- **Commit message sanitization** — shell metacharacters stripped from git messages

See [SECURITY.md](SECURITY.md) for the full threat model, network-activity audit, dependency tree, and how to verify it all yourself.

## Architecture

```
Sources/SecondBrainMCP/
├── main.swift                    # Entry point
├── Config/ServerConfig.swift     # CLI args -> config
├── Server/MCPServerSetup.swift   # Server init, all handlers
├── Core/
│   ├── PathValidator.swift       # Path security (struct, static)
│   ├── VaultManager.swift        # Note I/O (actor)
│   ├── ReferenceManager.swift    # PDF ops, zero write methods (Sendable struct)
│   ├── PDFPageRenderer.swift     # PDF page JPEG rendering + outline extraction (struct, static)
│   ├── PDFTextExtractor.swift    # PDFKit text extraction + search (struct, static)
│   ├── ReferenceCache.swift      # Lightweight search cache (enum, pure namespace)
│   ├── SearchEngine.swift        # Disk-based grep search (Sendable struct)
│   ├── GitManager.swift          # Git via /usr/bin/git (actor)
│   └── MarkdownParser.swift      # YAML frontmatter (struct, static)
└── Logging/AuditLogger.swift     # Operation log (actor)
```

**Concurrency model:** Actors for mutable state (VaultManager, GitManager, AuditLogger), Sendable structs for stateless I/O (ReferenceManager, SearchEngine), structs with static methods for pure logic (PathValidator, PDFPageRenderer, PDFTextExtractor, MarkdownParser), enum namespace for cache operations (ReferenceCache). Swift 6.2 strict concurrency — no data races by construction.

## Tests

```bash
swift test                            # Run all 92 tests
swift test --filter PathValidatorTests # Run specific suite
```

| Suite | Tests | What it covers |
|-------|-------|----------------|
| PathValidator (4 suites) | 24 | Traversal attacks, symlinks, edge cases |
| GitManager | 8 | Init, commit, log, sanitization |
| MarkdownParser (4 suites) | 16 | Frontmatter, links, generation |
| VaultManager (2 suites) | 28 | Read, list, filter, metadata, move, batch move |
| SearchEngine | 16 | Disk-based grep, snippet generation, reference search |
