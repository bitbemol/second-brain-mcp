# SecondBrainMCP

A local MCP server in Swift that gives MCP clients locator-only content search plus a format-aware CRUD API for a knowledge vault. Files under `notes/` are writable; `references/` remains structurally read-only. Successful note changes request a recoverable Git snapshot; snapshot failures are surfaced explicitly and an exact retry completes versioning without applying the mutation twice.

```
stdio-capable MCP client ──> SecondBrainMCP
                                  |
                                  +── notes/       (supported files, read/write, git tracked)
                                  +── references/  (supported files, read-only)
```

## Features

- **Compact file and directory tools** — four format-aware file CRUD tools plus one atomic `move_directory` operation for complete note subtrees
- **Locator-only vault search** — `search_vault` searches content but returns only note/file paths or physical PDF page numbers for follow-up with `read_file`
- **Concrete format routing** — Markdown, Canvas, JSON, CSV, HAR, patch/diff, log, common images, and PDF, each with explicitly registered operations
- **Multi-agent-safe note edits** — exact-byte revisions reject stale updates and deletes; caller-generated mutation IDs make timed-out mutations safely replayable
- **Capability discovery** — `secondbrain://file-capabilities` reports supported extensions, operations, and vault areas
- **Git snapshots** — note changes request a local `Vault snapshot`; concurrent agents may share one recovery point, and `references/` is never included
- **Soft deletes** — deleted files move to `.trash/`, never permanently removed
- **Image-based PDF reading** — dual content per page (extracted text + JPEG image), book page navigation, PDF outline/bookmarks
- **Read-only mode** — `--read-only` hides write tools and disables vault migration/Git mutation in the backend
- **Path security** — symlink resolution, traversal prevention, extension allowlists
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

Only `notes/` and `references/` need to exist. Writable startup prepares Git metadata as needed; read-only startup leaves the vault untouched.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--vault <path>` | *(required)* | Path to your vault directory |
| `--read-only` | `false` | Expose only `read_file` and `search_vault` |

## File API

The public API has four generic file CRUD tools, one atomic directory-move tool, and one read-only search tool. File CRUD callers must provide `format`; the server then verifies that the path extension and, where applicable, the decoded/parsed content agree with that format. Directory moves operate on the subtree path itself and therefore do not require or guess a file format.

Every mutation also requires a caller-generated UUID in `mutation_id`. Reuse that UUID only when retrying the exact same request after a timeout or lost response. Reads under `notes/` return an opaque exact-byte `revision`; `update_file` and `delete_file` require that value as `expected_revision`. A conflict means another actor changed the note, so the client must read and reconsider the new content rather than blindly retry. Read-only files under `references/` do not need revisions.

| Tool | Purpose |
|------|---------|
| `search_vault` | Locate matching whole-file atoms or physical PDF pages without returning their content |
| `create_file` | Validate/transform input, atomically create under `notes/`, and request a vault snapshot |
| `read_file` | Apply the format-specific reader for a file under `notes/` or `references/` |
| `update_file` | Apply a supported replace/append/patch operation under `notes/`, with stale-write protection |
| `delete_file` | Soft-delete a supported file under `notes/` to `.trash/`, then request a vault snapshot |
| `move_directory` | Atomically rename a complete `notes/` subtree—including nested files and directories—and request a vault snapshot |

### Directory moves

Use `move_directory` when a project or ticket folder changes lifecycle state. Supply the existing `source_path`, the exact unused `destination_path`, and a fresh `mutation_id`; there is no `format` argument because this is a structural operation over a set of file atoms. For example, one call can move `notes/in-progress/ticket-123` to `notes/completed/ticket-123` without returning or recreating any file content. Missing destination parents are created safely, the destination is never overwritten, moves into the source subtree are rejected, and case- or Unicode-equivalent source and destination paths are treated as the same directory. Success returns only `source_path`, `destination_path`, `mutation_id`, and `replayed`.

The complete subtree is validated before the descriptor-based no-follow rename, so hidden/package descendants and credential-bearing files are rejected before the move. The shared snapshot boundary then records the current `notes/` tree; pending changes from another agent may deliberately share that recovery point. Empty directories move on the filesystem, but Git has no directory objects and therefore cannot preserve an empty directory by itself. A vault-wide shared/exclusive tree lease prevents cooperating reads or writes from observing half of the path change. Successful files are immediately discoverable through `search_vault` at their destination paths; search itself remains read-only.

### Search

`search_vault` is a locator, not a reader. It searches content but returns only the atomic elements that contain a match: `path` and `format` for whole-file atoms, plus the one-based physical `page` for a PDF page. Use those values with `read_file` to retrieve the content.

Every request selects exactly one `location`: `notes` or `references`. It must also supply at least one search criterion: a text `query`, one or more `tags`, `created_from`, or `created_through`. Tags and created-date filters apply only to Markdown notes. Literal text matching is case-, diacritic-, and width-insensitive; every whitespace-separated query term must occur in the same atom. Exact phrases and repeated occurrences only determine stable result order.

Readable textual formats automatically participate without a search-specific format registry. Markdown notes are one atom each and expose their shared frontmatter `created` date and tags to metadata filters. JSON, CSV, HAR, Canvas, patch/diff, and log files are each searched as one whole-file atom. A format that needs a different representation can register a search atom provider without changing the public search contract.

PDF references are represented as one atom per physical page. Page text is cached by exact file revision under the vault's private `~/Library/Application Support/SecondBrainMCP/` data directory, never inside the vault or Git. Embedded PDF text is preferred; pages without embedded text use Vision OCR. Search returns only the matching page number. `read_file(format: pdf, page: ...)` then returns that page's bounded extracted text and rendered JPEG, preserving diagrams and non-text content for the model.

`limit` defaults to 20 and is capped at 50. When `next_cursor` is present, repeat the identical criteria with that cursor; for an unchanged vault, every matching atom remains reachable until a response omits `next_cursor`. The cursor is bound to the location and criteria, so it cannot continue a different search. Start a fresh search after vault changes if snapshot-style pagination is required.

Search results contain no snippets, file content, scores, diagnostics, or mutation revisions. Search discovers where information lives; `read_file` retrieves it and supplies the revision required for a later note update or delete.


### Formats and operations

| Format | Extensions | Create | Read | Update | Delete |
|--------|------------|:------:|:----:|:------:|:------:|
| `markdown` | `.md`, `.markdown` | notes | notes | replace/append/patch | notes |
| `canvas` | `.canvas` | notes | notes | replace | notes |
| `har` | `.har` | notes | notes | — | notes |
| `patch` | `.patch`, `.diff` | notes | notes | — | notes |
| `log` | `.log` | notes | notes | append | notes |
| `json` | `.json` | notes | notes | replace/patch | notes |
| `csv` | `.csv` | notes | notes | replace/append/patch | notes |
| `png` | `.png` | external image → clean/resized PNG | notes, references | — | notes |
| `gif` | `.gif` | external video + `video_to_gif` | notes, references | — | notes |
| `jpeg`, `webp`, `heic`, `tiff`, `bmp` | native aliases | — | notes, references | — | notes |
| `pdf` | `.pdf` | — | references | — | — |

The matrix is generated from registered operation bindings rather than maintained separately at runtime. Read `secondbrain://file-capabilities` for the server's effective capabilities and allowed vault areas for each operation. Internal handler identities stay private, so they can be refactored without changing the API. In `--read-only` mode, mutating operations disappear from both tool discovery and this resource.

Format-specific CRUD behavior stays behind the four endpoints:

- HAR input must have a valid, duplicate-key-free HAR `log` structure. Authorization/cookie headers, cookies, URL user information, authentication parameters, and credential fields in JSON/form request bodies are redacted before Git persistence; reads return a request/status/host/timing summary, with sanitized raw JSON only when requested.
- Git-tracked text writes reject high-confidence bearer, session, JWT, and provider-token patterns before persistence. Diagnostics identify the detector and line without repeating the credential; explicit redaction and documentation placeholders remain valid.
- Patch input must be a unified diff; reads report affected files, hunks, additions, and deletions.
- Logs default to the last 500 lines, support bounded line ranges, and can only be appended.
- JSON accepts any valid top-level JSON value, preserves its original representation, and validates replacements or exact text patches before persistence.
- CSV supports quoted fields, escaped quotes, embedded line breaks, and consistent column counts; every update validates the complete resulting table.
- Canvas input is structurally validated without re-serializing it, so extension/plugin keys survive.
- Images are decoded before import; PNG creation strips metadata/trailing payloads and caps the stored long edge. Animated GIF reads return sampled timed frames.
- PDF reads return extracted text plus rendered page images and support physical page, printed-page, and range navigation. Content queries belong to `search_vault`; `read_file` only retrieves selected pages.

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
- **No caller-selected commands** — only `/usr/bin/git`, with programmatic argument arrays
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
│       ├── Files/                      # Four generic CRUD tools + capabilities
│       └── Search/                     # Locator-only search schema and adapter
├── Backend/                            # Internal behavior; never imports MCP
│   ├── Concurrency/                    # Reusable cancellation-aware async gates
│   ├── Files/
│   │   ├── Ingress/                    # Stored-text request-to-bytes policy
│   │   ├── Operations/                 # Format-specific validation/transformation
│   │   ├── Routing/                    # Catalog, bindings, and routed service
│   │   ├── Storage/                    # Generic snapshots, persistence, and soft deletion
│   │   ├── Targets/                    # Validated readable/writable vault paths
│   │   ├── Transactions/               # Mutation, Git, receipt, and recovery sequencing
│   │   └── Validation/                 # Vault and external-source security
│   ├── Media/                          # Image and video processing
│   ├── Search/                         # Atom providers, literal matching, and pagination
│   └── …                               # Canvas, references, Git, logging, infrastructure
└── Shared/                             # Cross-boundary values and small utilities
    ├── Files/                          # Formats, requests, capabilities, and outputs
    ├── Search/                         # Search request/result/service contracts
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
`VaultMutationExecutor` persists the prepared mutation, requests a vault snapshot, and records durable retry state.
Format handlers never load external text sources or write vault files; `VaultCRUDStore` is the sole
persistence component for the generic API. Writable targets cannot represent `references/`.

**Concurrency model:** reads of the same note may overlap, while a fair keyed reader/writer actor
gives each note mutation exclusive access and prevents later readers from bypassing a queued writer
inside one runtime. Persistent advisory locks extend exclusion across independent MCP processes;
OS scheduling does not promise strict FIFO ordering between separate processes. Lock-file naming is
a versioned cooperating-host protocol: after an upgrade, fully stop and restart every MCP host for
the vault before resuming mutations; mixed old/new hosts are not supported. Unrelated note mutations may persist concurrently. Only `GitRepository` serializes the complete
Git init–stage–check–commit sequence, using one application-owned cross-process lock so cooperating agents
cannot race Git's index. Short receipt locks protect retry metadata without enclosing note persistence. Exact-byte revisions reject stale edits by
every cooperating MCP caller. The store also rechecks bytes immediately before persistence to catch
ordinary external edits, but an application that ignores these locks can still write inside the
final compare-to-rename window; filesystem path replacement has no universal cross-application CAS.
Reference reads bypass note locks and remain concurrent because `references/` has no writable
representation.

Cancellation while queued performs no mutation. Once persistence begins, recovery bookkeeping and
snapshotting continue even if the MCP caller stops listening; retrying the exact request with the same
`mutation_id` returns its durable result instead of applying it again. The server records an intent
and then a per-ID `persistenceStarted` state before bytes may change. If the process stops in that
uncertain phase, only the same mutation ID fails closed or enters operation-specific recovery;
unrelated mutations continue. A snapshot request may include pending note changes from several agents,
and a later request succeeds without a new commit when its state was already captured. Sudden machine
or storage power loss remains outside this guarantee because vault bytes, Git objects/refs, and the
external receipt directory are not one jointly synchronized filesystem transaction.

Completed receipts are retained for exact retries and are never silently expired. Their private
store has a hard 65,536-record / 512 MiB admission ceiling, with capacity reserved when an intent is
created so finalization cannot fail after vault persistence. At the ceiling, new mutation IDs fail
closed while every retained retry remains available; export or archival policy must be an explicit
administrative decision because deleting a receipt also deletes that ID's replay proof. Identity
locks use a fixed 256-stripe set, so retry coordination itself does not create one permanent file per
UUID. A constant-size durable quota ledger is reconciled against the receipt directory on the first
admission after bootstrap or after a detected crash/out-of-band change; ordinary saves update it in
constant work instead of rescanning every retained receipt. Reconciliation is entry-bounded and
removes only recognizable, validated crash-left receipt temporaries.
