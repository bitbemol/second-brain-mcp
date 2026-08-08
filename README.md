# SecondBrainMCP

A local MCP server in Swift that gives MCP clients compact, ranked search plus a format-aware CRUD API for a knowledge vault. Files under `notes/` are writable; `references/` remains structurally read-only. Every successful changed-byte mutation is committed to git; a post-persistence Git failure is surfaced explicitly and blocks later mutations until recovery.

```
stdio-capable MCP client ──> SecondBrainMCP
                                  |
                                  +── notes/       (supported files, read/write, git tracked)
                                  +── references/  (supported files, read-only)
```

## Features

- **Four generic file CRUD tools** — `create_file`, `read_file`, `update_file`, and `delete_file`; every request declares a concrete format
- **Ranked vault search** — `search_vault` supports smart, exact, phrase, lexical, and conservative fuzzy matching across safe snapshots of text notes
- **Concrete format routing** — Markdown, Canvas, JSON, CSV, HAR, patch/diff, log, common images, and PDF, each with explicitly registered operations
- **Multi-agent-safe note edits** — exact-byte revisions reject stale updates and deletes; caller-generated mutation IDs make timed-out mutations safely replayable
- **Capability discovery** — `secondbrain://file-capabilities` reports supported extensions, operations, and vault areas
- **Git auto-commit** — every successful changed-byte write creates a scoped commit with `[SecondBrainMCP]` prefix
- **Soft deletes** — deleted files move to `.trash/`, never permanently removed
- **Image-based PDF reading** — dual content per page (extracted text + JPEG image), book page navigation, PDF outline/bookmarks
- **Read-only mode** — `--read-only` hides write tools and disables vault migration/Git mutation in the backend
- **Path security** — symlink resolution, traversal prevention, extension allowlists
- **Audit log** — best-effort operation records live under `~/Library/Application Support/SecondBrainMCP/`
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
| `--read-only` | `false` | Expose only `read_file` and `search_vault` |

## File API

The public API has four generic CRUD tools plus one read-only search tool. CRUD callers must provide `format`; the server then verifies that the path extension and, where applicable, the decoded/parsed content agree with that format. This is deliberate: clients can see the allowed enum before sending data instead of guessing what the server might accept.

Every mutation also requires a caller-generated UUID in `mutation_id`. Reuse that UUID only when retrying the exact same request after a timeout or lost response. Reads under `notes/` return an opaque exact-byte `revision`; `update_file` and `delete_file` require that value as `expected_revision`. A conflict means another actor changed the note, so the client must read and reconsider the new content rather than blindly retry. Read-only files under `references/` do not need revisions.

| Tool | Purpose |
|------|---------|
| `search_vault` | Rank matching text notes by title, heading, tags, path, or content without returning a mutation revision |
| `create_file` | Validate/transform input, atomically create under `notes/`, and git-commit |
| `read_file` | Apply the format-specific reader for a file under `notes/` or `references/` |
| `update_file` | Apply a supported replace/append/patch operation under `notes/`, with stale-write protection |
| `delete_file` | Soft-delete a supported file under `notes/` to `.trash/`, then git-commit |

### Search

Only `query` is required. `strategy` defaults to `smart`, `limit` defaults to 20 (hard cap 50), and `minimum_relevance` defaults to `0.60` on a normalized `0...1` scale. Set the floor to `0` only when broad partial recall is more useful than precision. Omitted `fields` or `formats` mean every value advertised by the tool schema. `path_prefix` can narrow traversal to a canonical, non-hidden, non-package directory under `notes/`.

| Strategy | Behavior |
|----------|----------|
| `smart` | Prefers literal and ordered matches, ranks lexical coverage, then repairs conservative likely typos |
| `exact` | Case/diacritic-insensitive literal substring; punctuation remains significant |
| `phrase` | Adjacent ordered terms across punctuation and whitespace |
| `lexical` | Word coverage ranked by field importance |
| `fuzzy` | Bounded typo matching, including adjacent transpositions; one- and two-character terms remain exact-only |

Search covers textual formats readable under `notes/`: Markdown, Canvas, HAR, patch/diff, log, JSON, and CSV. Markdown results are section-aware and rank title above heading, tags, path, and body. Canvas is projected into node values instead of raw layout JSON, and matching results include the node ID, kind, and field. One best section or structured node is returned per file for breadth. Every result includes `relevance` (ranking strength, not probability), `term_coverage`, contributing `matched_fields`, and `complete_query_fields` that individually satisfied the whole query. Ranking and tie-breaking are stable for the examined corpus. Smart search performs an exhaustive literal pass before fair per-file phrase/lexical/fuzzy work, so expensive evidence files cannot hide literal hits in later notes. Ordinary notes and smaller files are admitted before large HAR evidence, with an 8 MiB live-search ceiling per file; omitted files remain explicitly readable through `read_file`.

Coverage is explicit in every response. `more_results_available` means matching results were omitted by a result or encoded-output limit. `coverage_incomplete` means some requested searchable content could not be fully evaluated. `resource_limited_file_count` is the number of known files wholly or partially omitted by a resource ceiling; it is necessarily a lower bound if directory traversal itself ends before every entry is discovered. `resource_limit_samples` gives at most eight stable, non-sensitive `{path, reason, impact}` examples and is never exhaustive. A partially evaluated file can appear in both `searched_file_count` and `resource_limited_file_count`, so the counters are facts rather than a partition to sum. `skipped_file_count` covers eligible-file safe-read, availability, containment, or parse failures, while `skipped_sensitive_file_count` remains separate. The legacy `truncated` field is the union of `more_results_available` and `coverage_incomplete`.

Search results are discovery data, not mutation authorization: they intentionally contain no revision. Call `read_file` before an update or delete. Broad PDF-library search is not performed live because opening every PDF would make latency and memory unpredictable; use `read_file(format: pdf, query: ...)` after identifying a PDF. HAR is shape-bounded and sanitized before matching, and other legacy text containing high-confidence credentials is skipped rather than projected into snippets. Whole-vault scans share a bounded in-process queue and one cancellation-aware vault-scoped cross-process permit, so concurrent agents or MCP processes cannot multiply the corpus memory ceiling; canceled queued calls leave the line immediately. The complete MCP result—including compatibility JSON text and structured content—is byte-bounded.

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
│       └── Search/                     # One ranked read-only search tool
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
│   ├── Search/                         # Bounded corpus extraction and ranking
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
`VaultMutationExecutor` serializes the prepared storage mutation, Git commit, and audit record.
Format handlers never load external text sources or write vault files; `VaultCRUDStore` is the sole
persistence component for the generic API. Writable targets cannot represent `references/`.

**Concurrency model:** reads of the same note may overlap, while a fair keyed reader/writer actor
gives each note mutation exclusive access and prevents later readers from bypassing a queued writer
inside one runtime. Persistent advisory locks extend exclusion across independent MCP processes;
OS scheduling does not promise strict FIFO ordering between separate processes. A separate
vault-wide cross-process mutation lock keeps filesystem persistence, the Git index/commit, audit logging, and
the durable retry receipt in one ordered critical phase. Exact-byte revisions reject stale edits by
every cooperating MCP caller. The store also rechecks bytes immediately before persistence to catch
ordinary external edits, but an application that ignores these locks can still write inside the
final compare-to-rename window; filesystem path replacement has no universal cross-application CAS.
Reference reads bypass note locks and remain concurrent because `references/` has no writable
representation.

Cancellation while queued performs no mutation. Once persistence begins, the critical phase runs to
completion even if its MCP caller stops listening; retrying the exact request with the same
`mutation_id` returns its durable result instead of applying it again. The server writes an
in-progress intent before that point of no return. If the process stops unexpectedly during that
narrow phase, a surviving active marker blocks other mutations and permits only conservative exact-request
recovery rather than risking a duplicate mutation. Sudden machine or storage power loss is outside
this transaction guarantee because vault bytes, Git objects/refs, and the external receipt directory
are not one jointly synchronized filesystem transaction.
