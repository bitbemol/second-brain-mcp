# SecondBrainMCP

A local MCP server in Swift that gives MCP clients a compact, format-aware CRUD API for a knowledge vault. Files under `notes/` are writable; `references/` remains structurally read-only. Every mutation is automatically committed to git.

```
stdio-capable MCP client ──> SecondBrainMCP
                                  |
                                  +── notes/       (supported files, read/write, git tracked)
                                  +── references/  (supported files, read-only)
```

## Features

- **Four generic file CRUD tools** — `create_file`, `read_file`, `update_file`, and `delete_file`; every request declares a concrete format
- **Concrete format routing** — Markdown, Canvas, HAR, patch/diff, log, common images, and PDF, each with explicitly registered operations
- **Capability discovery** — `secondbrain://file-capabilities` reports supported extensions, operations, and vault areas
- **Git auto-commit** — every write creates a commit with `[SecondBrainMCP]` prefix
- **Soft deletes** — deleted files move to `.trash/`, never permanently removed
- **Image-based PDF reading** — dual content per page (extracted text + JPEG image), book page navigation, PDF outline/bookmarks
- **Read-only mode** — `--read-only` hides write tools and disables vault migration/Git mutation in the backend
- **Path security** — symlink resolution, traversal prevention, extension allowlists
- **Audit log** — every operation is logged under `~/Library/Application Support/SecondBrainMCP/`
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

SecondBrainMCP uses the standard stdio MCP transport. The examples below configure Claude Desktop
and Claude Code; another MCP client can use the same executable and arguments when it supports
launching local stdio servers.

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

## Vault Structure

```
~/SecondBrain/
├── notes/              <- Supported files (editable, git tracked)
│   ├── projects/
│   ├── journal/
│   └── artifacts/
├── references/         <- PDF/image reference library (read-only)
├── INSTRUCTIONS.md     <- Optional: custom rules for the AI (see below)
├── .git/               <- Auto-created on first run
└── .trash/             <- Soft-deleted files land here
```

Only `notes/` and `references/` need to exist. Writable startup prepares Git metadata as needed; read-only startup leaves the vault untouched. Size-rotated audit logs live outside the vault under `~/Library/Application Support/SecondBrainMCP/`.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--vault <path>` | *(required)* | Path to your vault directory |
| `--read-only` | `false` | Expose only `read_file` |

## File API

File CRUD has exactly four MCP tools. The caller must provide `format`; the server then verifies that the path extension and, where applicable, the decoded/parsed content agree with that format. This is deliberate: clients can see the allowed enum before sending data instead of guessing what the server might accept.

| Tool | Purpose |
|------|---------|
| `create_file` | Validate/transform input, atomically create under `notes/`, and git-commit |
| `read_file` | Apply the format-specific reader for a file under `notes/` or `references/` |
| `update_file` | Apply a supported replace/append/patch operation under `notes/`, with stale-write protection |
| `delete_file` | Soft-delete a supported file under `notes/` to `.trash/`, then git-commit |

### Formats and operations

| Format | Extensions | Create | Read | Update | Delete |
|--------|------------|:------:|:----:|:------:|:------:|
| `markdown` | `.md`, `.markdown` | notes | notes | replace/append/patch | notes |
| `canvas` | `.canvas` | notes | notes | replace | notes |
| `har` | `.har` | notes | notes | — | notes |
| `patch` | `.patch`, `.diff` | notes | notes | — | notes |
| `log` | `.log` | notes | notes | append | notes |
| `png` | `.png` | external image → clean/resized PNG | notes, references | — | notes |
| `gif` | `.gif` | external video + `video_to_gif` | notes, references | — | notes |
| `jpeg`, `webp`, `heic`, `tiff`, `bmp` | native aliases | — | notes, references | — | notes |
| `pdf` | `.pdf` | — | references | — | notes |

The matrix is generated from registered operation bindings rather than maintained separately at runtime. Read `secondbrain://file-capabilities` for the server's effective capabilities and allowed vault areas for each operation. Internal handler identities stay private, so they can be refactored without changing the API. In `--read-only` mode, mutating operations disappear from both tool discovery and this resource.

Format-specific behavior stays behind the four endpoints:

- HAR input must have a valid HAR `log` structure; reads return a request/status/host/timing summary, with raw JSON only when requested.
- Patch input must be a unified diff; reads report affected files, hunks, additions, and deletions.
- Logs default to the last 500 lines, support bounded line ranges, and can only be appended.
- Canvas input is structurally validated without re-serializing it, so extension/plugin keys survive.
- Images are decoded before import; PNG creation strips metadata/trailing payloads and caps the stored long edge. Animated GIF reads return sampled timed frames.
- PDF reads return extracted text plus rendered page images and support page, printed-page, range, and query navigation.

## Resources

| URI | Description |
|-----|-------------|
| `secondbrain://file-capabilities` | Effective file formats, extensions, CRUD operations, and vault areas |

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
- **No arbitrary shell execution** — only `/usr/bin/git`, with programmatic argument arrays
- **Structural write boundaries** — `WritableFileTarget` cannot represent a path under `references/`
- **Soft deletes only** — files are never permanently deleted
- **Commit message sanitization** — shell metacharacters stripped from git messages

See [SECURITY.md](SECURITY.md) for the full threat model, network-activity audit, dependency tree, and how to verify it all yourself.

## Architecture

```
Sources/SecondBrainMCP/
├── Frontend/                           # Public CLI and MCP API boundary
│   ├── Application/main.swift
│   ├── Configuration/                  # Argument parsing
│   └── MCP/
│       └── Files/                      # Four generic CRUD tools + capabilities
├── Backend/                            # Internal behavior; never imports MCP
│   ├── Concurrency/                    # Reusable cancellation-aware async gates
│   ├── Files/
│   │   ├── Ingress/                    # Stored-text request-to-bytes policy
│   │   ├── Operations/                 # Format-specific validation/transformation
│   │   ├── Routing/                    # Catalog, bindings, and routed service
│   │   ├── Storage/                    # Generic snapshots, persistence, and soft deletion
│   │   ├── Targets/                    # Validated readable/writable vault paths
│   │   ├── Transactions/               # Mutation, Git, and audit sequencing
│   │   └── Validation/                 # Vault and external-source security
│   ├── Media/                          # Image and video processing
│   └── …                               # Canvas, references, Git, logging, infrastructure
└── Shared/                             # Cross-boundary values and small utilities
    ├── Files/                          # Formats, requests, capabilities, and outputs
    └── Logging/                        # Shared stderr logger
```

Dependencies flow inward as `Frontend → Backend → Shared`. Frontend translates CLI/MCP
inputs into plain Swift values. Backend owns vault behavior, routing, processing, and persistence.
Shared contains only stable contracts or genuinely cross-boundary utilities; feature orchestration
does not belong there. Backend and Shared never depend on Frontend.

`VaultRuntime` is the backend composition root. `FileFormatDefinition` is the wiring point: each
concrete format registers only the operations it supports and binds those operations to reusable
functions. `VaultFileService` validates and routes requests; `TextFileIngress` converts stored-text
create requests into bounded inline bytes before their semantic handler; and
`VaultMutationExecutor` serializes the prepared storage mutation, Git commit, and audit record.
Format handlers never load external text sources or write vault files; `VaultCRUDStore` is the sole
persistence component for the generic API. Writable targets cannot represent `references/`.

**Concurrency model:** actors serialize mutable state and I/O; immutable routing definitions and
stateless handlers are `Sendable`. `AsyncExclusiveGate` keeps each generic file mutation and its
Git commit together inside `VaultMutationExecutor`, and also prevents actor reentrancy from running
multiple video conversions at once. Snapshot comparison rejects stale updates from concurrent
external edits.
