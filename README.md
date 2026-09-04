# SecondBrainMCP

A local MCP server in Swift that gives MCP clients bounded file discovery, locator-only content and link queries, plus a format-aware CRUD API for a knowledge vault. Files under `notes/` are writable; `references/` remains structurally read-only. Successful note changes await a recoverable Git snapshot, and snapshot failures are surfaced explicitly.

```
stdio-capable MCP client ──> SecondBrainMCP
                                  |
                                  +── notes/       (supported files, read/write, privately snapshotted)
                                  +── references/  (supported files, read-only)
```

## Features

- **Eight composable agent tools** — file discovery, content search, link traversal, four format-aware CRUD operations, and one atomic file-or-directory `move_path`
- **Content-free discovery** — `list_files`, `search_vault`, and `query_links` return bounded structured locators instead of dumping file contents
- **Metadata views** — `read_file(view: metadata)` returns bounded Markdown or PDF facts without page text, images, or document bodies
- **Concrete format routing** — Markdown, Canvas, JSON, CSV, HAR, patch/diff, log, common images, and PDF, each with explicitly registered operations
- **Bounded text reads** — UTF-8 documents default to 64 KiB revision-guarded chunks with explicit continuation metadata; no silent truncation or split Unicode scalars
- **Multi-agent-safe vault access** — concurrent reads overlap, complete mutations are exclusive through their Git snapshot, and exact-byte revisions reject stale updates and deletes
- **Git snapshots without user-repository contention** — note changes are recorded in a private bare repository outside the vault; the user's `.git`, `HEAD`, staging index, refs, configuration, hooks, attributes, and locks are never borrowed or changed
- **Soft deletes** — deleted files move to `.trash/`, never permanently removed; parent directories and their unrelated contents are preserved
- **Atomic PDF page reading** — each requested physical page returns bounded extracted text plus a PNG image; single pages, ordered page sets, and inclusive ranges are supported
- **Read-only mode** — `--read-only` hides write tools and disables vault migration/Git mutation in the backend
- **Path security** — symlink resolution, traversal prevention, extension allowlists
- **Works alongside Obsidian, iA Writer, Logseq** — only `notes/` enters recovery snapshots; root-level editor state such as `.obsidian/` is outside the snapshot scope
- **Custom instructions** — drop an `INSTRUCTIONS.md` in your vault root to define your own conventions

## Quick Start

```bash
# 1. Build
swift build -c release
# Binary is at .build/release/second-brain-mcp

# 2. Create a vault
./setup-vault.sh

# 3. Connect to Claude or Codex (see below)

# 4. Ask your MCP client: "What notes do I have?"
```

## Requirements

- Swift 6.3 or later (builds on 6.4 — note the [build-output path change](#installation) on 6.4+)
- macOS 26 (Tahoe) or later
- Xcode 26 or later

## Installation

```bash
git clone https://github.com/bitbemol/second-brain-mcp.git
cd second-brain-mcp
swift build -c release
```

The binary is at `.build/release/second-brain-mcp`. You can copy it anywhere:

```bash
cp .build/release/second-brain-mcp /usr/local/bin/
```

> **Always use the `.build/release/second-brain-mcp` path — not an architecture-specific one** like `.build/arm64-apple-macosx/release/second-brain-mcp`. Swift 6.4 changed SwiftPM's default build system from `native` (which wrote products to `.build/<triple>/release/`) to `swiftbuild` (which writes to `.build/out/Products/Release/`). SwiftPM keeps `.build/release` and `.build/debug` as symlinks to the current layout under **both** systems, so pinning to the symlink survives toolchain upgrades. Pinning to an arch-specific path will silently keep launching a **stale binary** after you upgrade Swift — the build succeeds, but lands somewhere your config no longer points to.

When redistributing the binary, include the [vendored SDK license](Vendor/swift-sdk/LICENSE)
and the other dependency licenses. The [SDK provenance record](Vendor/swift-sdk/README.md)
documents its pinned source and local compatibility fixes.

## Connecting to Claude and Codex

SecondBrainMCP uses the standard stdio MCP transport. The examples below configure Claude Desktop,
Claude Code, and Codex. Another MCP client can use the same executable and arguments when it supports
launching local stdio servers. Concurrent responses remain complete newline-delimited frames, and
input is read on demand. Incoming frames above 192 MiB or incomplete frames at EOF terminate the
connection. After any lost mutation response, observe the current state before retrying.

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

### Option C: Codex (desktop app, CLI, and IDE extension)

The quickest setup uses the Codex CLI:

```bash
codex mcp add second-brain -- \
  /absolute/path/to/.build/release/second-brain-mcp \
  --vault /absolute/path/to/your/vault
```

This writes the server to the user-level Codex configuration. The Codex desktop app, CLI, and IDE
extension share that configuration, so one registration makes the server available across all three.
Verify it from a terminal or from the Codex TUI:

```bash
codex mcp list
```

```text
/mcp
```

You can also configure it from the Codex desktop app: open **Settings → MCP servers**, select
**Add server**, choose **STDIO**, enter the same executable and arguments, save, and restart Codex.
For a trusted-project-only configuration, place the equivalent server entry in
`.codex/config.toml` instead of the default `~/.codex/config.toml`. See the
[official Codex MCP documentation](https://developers.openai.com/codex/mcp/) for configuration details.

### Updating the server

After pulling changes or editing the code, rebuild and **relaunch the client** so new or changed tools are picked up:

```bash
swift build -c release
```

Then fully restart the active client: **Cmd+Q and reopen Claude Desktop or Codex**, or start a new `claude` or `codex` session. A running server keeps serving its old tool list until the process is relaunched — rebuilding alone isn't enough.

If new tools still don't appear, confirm the client's `command` points at `.build/release/second-brain-mcp` (the symlink, see [Installation](#installation)) and not a stale architecture-specific path.

## Vault Structure

```
~/SecondBrain/
├── notes/              <- Supported files (editable, privately snapshotted)
│   ├── projects/
│   ├── journal/
│   └── artifacts/
├── references/         <- PDF/image reference library (read-only)
├── INSTRUCTIONS.md     <- Optional: custom rules for the AI (see below)
├── .git/               <- Optional user-owned repository; never managed by SecondBrainMCP
├── .obsidian/          <- Optional editor state; outside SecondBrainMCP snapshot scope
└── .trash/             <- Soft-deleted files land here
```

Only `notes/` and `references/` need to exist. Writable startup connects the MCP transport before recovering pending note changes, so initialization and tool discovery do not wait behind a large or contended snapshot. Recovery holds a shared vault lease: reads and discovery remain available while mutations wait for recovery to finish. If recovery fails after connection, the server stays connected for discovery and reads while the current mutation reports the recovery error instead of terminating the process; after the underlying Git or storage condition is corrected, the next mutation retries recovery without requiring a server restart. Recovery and transport completion are logged to stderr. On input EOF, the server closes tool admission, cancels outstanding calls, and waits for their work to unwind; persistence that has already started still finishes its required snapshot. Read-only startup neither initializes snapshots nor resolves Git.

Writable mode stores recovery history in a per-vault bare repository at `~/Library/Application Support/SecondBrainMCP/<vault-path-hash>/git-snapshots-v1.git`, with UUID-isolated transaction indexes beside it. Each transaction rebuilds only the current `notes/` tree and publishes a uniquely named private ref under `refs/second-brain-mcp/snapshots/`. A dedicated cross-process lock serializes that private repository. The complete snapshot attempt, including lock admission, has a cooperative 120-second deadline; an overrunning Git child has its process group terminated and reports snapshot failure instead of waiting indefinitely. As with any local application, an underlying kernel filesystem call that never returns cannot be universally interrupted in user space.

SecondBrainMCP never creates, reads, changes, unlocks, repairs, or waits for a vault `.git` repository or `.git/index.lock`. User ignore rules, sparse-checkout state, hooks, attributes, filters, staged files, branches, and worktrees are not part of the snapshot boundary. Root-level Obsidian/editor files and every other path outside `notes/` are not scanned or snapshotted, and SecondBrainMCP does not add `.gitignore` rules for third-party tools. Consequently, `git status` and Xcode's Changes view continue to show only the user's own repository state; commit or ignore those files according to that repository's policy.

Snapshots force inclusion of the exact regular-file bytes under `notes/`, independent of user ignore and attribute rules. Symbolic links, special filesystem entries, and nested Git repositories under `notes/` fail closed because they cannot be represented as recoverable note bytes. The product accepts only a canonical Apple-signed Git executable found in the selected developer directory, Xcode, Xcode beta, or Command Line Tools; `/usr/bin/git` shims are rejected. Upgrading from the former user-repository snapshot design creates a private baseline from the current `notes/` state and leaves all old user refs/history untouched. Moving or copying a vault to another canonical path creates a separate private baseline because private storage is keyed by that path.

Exact recovery deliberately examines the complete `notes/` corpus rather than trusting cached file metadata, so snapshot work scales with the number and size of notes. This is what lets a mutation coalesce ordinary edits made by another local app without risking stale recovery bytes. Keep editor caches, generated data, and bulky non-note content outside `notes/`; exceptionally large or slow/cloud-backed note trees can reach the cooperative 120-second failure boundary. A retained Git index would be faster but would weaken this exact-current-tree guarantee, so it is not used as a hidden optimization.

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--vault <path>` | *(required)* | Path to your vault directory |
| `--read-only` | `false` | Expose only `list_files`, `search_vault`, `query_links`, and `read_file` |

## File API

The public API has eight composable tools: three bounded discovery/query tools, four generic file CRUD tools, and one atomic file-or-directory move. File CRUD callers provide `format`; the server verifies that the extension and, where applicable, decoded content agree. Schemas reject unknown arguments, `update_file` requires an explicit `mode`, and mutations of existing files require a revision read from the exact source bytes. Directory moves remain structural and therefore omit file-only fields.

Upgrading from v0.7.1 is a breaking API migration; see [Migrating from v0.7.1 to v2](MIGRATION-v2.md) for capability mappings, removed resources, new behavior, and restart guidance.

Reads under `notes/` return an opaque exact-byte `revision`; `update_file`, `delete_file`, and file-form `move_path` require that value as `expected_revision`. UTF-8 Markdown, Canvas, HAR, patch, JSON, and CSV reads return at most 64 KiB by default and include `text_window` in structured output and the trailing JSON metadata block. When `next_byte_offset` is present, continue with that value as `byte_offset` and the same revision as `expected_revision`; a changed file is rejected instead of mixing chunks from different versions. Callers may select `max_bytes` from 4 bytes through 256 KiB, and chunk boundaries never split a UTF-8 scalar. Read-only files under `references/` do not need revisions. A mutation call returns only after its filesystem change and required Git snapshot finish. If the transport loses that response, read the target state before deciding whether another mutation is needed.

| Tool | Purpose |
|------|---------|
| `list_files` | Browse paths and lightweight filesystem metadata without search terms or content reads |
| `search_vault` | Locate matching file, PDF-page, or Canvas-node atoms without returning their content |
| `query_links` | Resolve wiki targets or traverse local wiki/inline Markdown links and grouped backlinks without snippets |
| `create_file` | Validate/transform input, atomically create under `notes/`, and request a vault snapshot |
| `read_file` | Read bounded content, inspect images (`render: true` opts into visuals), or request Markdown/PDF metadata |
| `update_file` | Apply a supported replace/append/patch operation under `notes/`, with stale-write protection |
| `delete_file` | Soft-delete a supported file under `notes/` to `.trash/`, then request a vault snapshot |
| `move_path` | Atomically rename one revision-guarded supported file or one complete `notes/` subtree |

### Multi-file workflows

Each mutation call is durable independently; there is no multi-file transaction or
batch-delete API. Concurrent calls are coordinated but do not promise one shared
commit or all-or-nothing completion as a group. Use one multi-replacement `patch`
for edits to one file and `move_path(kind: directory)` for an atomic subtree move.
Do not infer transaction semantics from parallel tool calls or retry an entire
workflow after losing one response. A future batch API needs explicit partial-failure
and crash-recovery semantics; automatic delayed snapshots would weaken the current
successful-response durability contract.

### Failure handling

File CRUD, `move_path`, and `list_files` failures return actionable text and
`structuredContent.error` with `code`, `state`, and `retry`.
Routine codes include `ALREADY_EXISTS`, `NOT_FOUND`, `DIRECTORY_NOT_FOUND`,
`INVALID_PATH`, `MISSING_TRANSFORM`, and `REVISION_CONFLICT`; unclassified failures
remain opaque `INTERNAL_ERROR` responses without host paths or framework details.

`state: not_applied` means rejection before persistence: request decoding or protected
preparation failed without applying the requested mutation. `read_only` means the
operation did not mutate. Once persistence starts, failures conservatively report
`state: unknown` and `retry: inspect_state`, even for a recognizable error, because
bytes may have changed before a later failure or failed Git snapshot. Inspect current
state before deciding to retry. `retry: correct_request` means fix the request before
repeating it; neither hint authorizes blind replay or supplies a replacement revision.

### Creation inputs

File paths are relative to the vault root and include their area: use `notes/QA/example.md`, not `QA/example.md`. Creation is limited to `notes/`; the destination must not already exist.

Text formats use inline `content`. Canvas content is a JSON object, for example `{"nodes":[],"edges":[]}`, not a root array. PNG and GIF creation instead require `source`: a local regular-file path outside the vault. Data URIs and existing vault files are not import sources. PNG accepts a supported image; GIF requires a video and `transform: "video_to_gif"`. Creation reports the finalized GIF's dimensions, frame count, quantized duration, and effective frame rate, not the source video's facts; frame-delay quantization can change duration slightly. External sources are never modified.

Example `create_file` arguments (replace the external paths with your own generated fixtures):

```json
{"format":"png","path":"notes/QA/image.png","source":"/absolute/path/to/external/image.png"}
```

```json
{"format":"gif","path":"notes/QA/clip.gif","source":"/absolute/path/to/external/clip.mov","transform":"video_to_gif"}
```

### Deletion and recovery

A successful `delete_file` returns `path`, `area`, `trash_path`, and `deleted_revision`.
The trash locator identifies the exact retained bytes; it is not an undo token or
authority for an MCP read/move. Keep the receipt if recovery may be needed.

Recovery is currently a user-controlled filesystem operation, not an MCP tool:

1. Stop MCP clients and avoid other vault edits while recovering.
2. In Finder, show hidden files and locate the receipt's path beneath the vault's
   `.trash/` directory. Copy that file to an unused, supported path under `notes/`,
   retaining its format extension. Do not overwrite an existing note; keep the trash copy.
3. Restart a writable MCP client so startup records the recovered note in Git.
   Read the restored path and compare its revision with `deleted_revision`.

The server never automatically expires or purges trash. Retention is indefinite
until the local user removes it; there is no MCP purge operation. The trash copy
is local recovery storage, not an independent backup. If a deletion response was
lost, inspect current state before retrying; no receipt should be inferred from a
failed or missing response.

### Path moves

Use `move_path` instead of a read-create-delete sequence when an existing file or project subtree changes location. For `kind: file`, provide the source's concrete `format` and exact `expected_revision` returned by `read_file`; the source and destination extensions must match. For `kind: directory`, omit those file-only fields. Supply the existing `source_path` and exact unused `destination_path`. Missing destination parents are created safely, destinations are never overwritten, moves into the source subtree are rejected, and case- or Unicode-equivalent paths are treated as identical. Success returns only `source_path` and `destination_path`.

The selected file or complete subtree is validated before the descriptor-based no-follow rename. A supported dot-named regular file such as `.gitkeep.md` can move with its subtree after the same content, encoding, credential, size, and descriptor checks as other files. Hidden directories, Finder-hidden entries, packages, unsupported dotfiles such as `.env` or `.gitkeep`, symlinks, stale files, and credential-bearing content remain rejected. The global mutation lease remains held through the rename and Git snapshot, so cooperating reads cannot observe a half-completed operation. Pending note changes may deliberately share that snapshot. Empty directories move on the filesystem, but Git has no directory objects and therefore cannot preserve an empty directory by itself. Successful files are immediately discoverable through `search_vault` at their destination paths; search itself remains read-only.

### File discovery

Use `list_files` when the goal is to inspect what exists rather than match content. Select one `area` (`notes` or `references`), then optionally narrow with an area-relative `directory`, `recursive: false`, or concrete `formats`. Results contain only canonical path, format, byte count, and modified time; the tool does not open document bodies. Listing, content search and link queries skip hidden entries and nested package directories (such as application bundles); explicitly selecting a package as a discovery scope is rejected. This discovery policy does not change direct access to an explicitly named, valid readable file. Pages default to 100 entries and are capped at 500. Continue an unchanged request with `next_cursor`; if matching files change, restart without the stale cursor.

### Link queries

Use `query_links` when the relationship is known. `direction: resolve` maps a wiki `target` to matching supported paths and marks ambiguity; optional `from_path` ranks nearby candidates first. `direction: outgoing` takes the source `notes/...md` path in `target`. `direction: backlinks` defaults to one source/target pair with `occurrence_count`, avoiding repeated copies of the same note. To inspect a group, use `group_by: occurrence` and `source_path`. Resolved entries include `resolved_format` for a subsequent `read_file` call. Grouping and source filters apply only to backlinks.

For `[[target|Display label]]`, resolve `target`, not the display alias `Display label`; aliases are not indexed as alternate identities.

Outgoing links and backlinks recognize wiki links/embeds and inline Markdown links/images. Inline destinations resolve relative to their source, with URI decoding once; wiki destinations use vault/proximity rules. Fragments, aliases, ambiguity and unresolved local targets remain structured. Escapes, fenced/inline code and external URLs are excluded; reference-style Markdown is not supported. Metadata targets are raw identifiers, not necessarily read-ready paths: use an outgoing query on their source to resolve them.

Results contain no snippets or bodies. Every page includes `coverage`: `complete: false` means some eligible sources failed, not that their links are absent. `next_cursor` pages already examined results, independently of coverage. Continue with unchanged semantic criteria; `limit` may change. Content or relevant path-namespace changes invalidate a cursor.

### Search

`search_vault` is a locator, not a reader. It searches content but returns only atomic coordinates: `path` and `format` for whole-file atoms, one-based physical `page` for PDF pages, or `canvas_node_id` plus `canvas_field` for a searchable Canvas node field. Use the path and format with `read_file` to retrieve content.

Every request selects exactly one `location`: `notes` or `references`. Optional area-relative `directory` and concrete `formats` narrow eligibility before content is opened. It must also supply at least one search criterion: a text `query`, one or more `tags`, `created_from`, or `created_through`. Tags and created-date filters apply only to Markdown notes. Literal text matching is case-, diacritic-, and width-insensitive; every whitespace-separated query term must occur in the same atom. Exact phrases and repeated occurrences only determine stable result order.

Tool discovery advertises only formats with an effective search representation in at least one area. Selecting an unavailable format returns a search-capability error, with `list_files`/`read_file` as alternatives; readable images do not implicitly have OCR search. Readable textual formats automatically participate without a search-specific format registry. Markdown notes are one atom each and expose their shared frontmatter `created` date and tags to metadata filters. JSON, CSV, HAR, patch/diff, and log files are each searched as one raw UTF-8 whole-file atom; search does not validate their format-specific syntax. `coverage.complete` describes examination of the search representation, not certification that a later strict `read_file` will accept every stored document. Canvas is searched as bounded node-field atoms so a result identifies the exact node ID and field instead of returning the entire JSON document as one match. A format that needs a different representation can register a search atom provider without changing the public search contract. An individual file that cannot be decoded into its search representation, exceeds its limits, is unreadable, or changes during capture contributes no partial matches and makes `coverage.complete` false. Incomplete search coverage includes exact `failed_files` and `failed_by_format` counts, including failures omitted from the at-most-three whole-path/category samples. The format counts sum to `failed_files`; the entire coverage object remains within 2 KiB, and `samples_truncated` reports omitted samples. Incomplete coverage also includes `complete_formats`: the eligible formats fully examined without a source failure under this request's area, directory, and metadata filters. An empty first page establishes no matches only within those listed formats and that request scope; an empty continuation page does not. Formats outside the list remain unproven, and a metadata-only search never certifies unrelated JSON or HAR files. This avoids a second search merely to confirm an already-examined format. Narrow `directory` or `formats` when that scope matches the question—for example `formats: ["markdown", "json"]`—but complete results for a narrowed scope cannot establish global absence. Unknown traversal failures, path-policy failures, cancellation and request-level resource exhaustion fail the entire request.

Search permits up to 10,000 eligible files, 100,000 scanned entries, 256 MiB of attempted source bytes and 100,000 atoms. Per-format file and extraction limits still apply. Separate 8 MiB budgets bound traversal path strings and each retained candidate/capture manifest. It captures immutable inputs under the cooperating-vault read lease, then releases that lease before extraction and ranking; it does not retain the entire corpus in memory. Capture storage is private, outside the vault/Git, bounded and cleaned after use. Lowering result `limit` does not reduce scan work: narrow `directory`, `formats` or the searched area instead. A warm query still reconciles exact source bytes; caching is not permission to serve stale results.

PDF references are represented as one atom per physical page. Page text is cached in immutable, integrity-checked generations by exact file revision under the vault's private `~/Library/Application Support/SecondBrainMCP/` data directory, never inside the vault or Git. Cache failures fall back to bounded extraction; cache publication is best-effort and never part of mutation durability. Extraction rejects a page above 2 MiB or document text above 64 MiB instead of silently truncating it. Embedded PDF text is preferred; pages without embedded text use Vision OCR. OCR is approximate, so complete search coverage does not guarantee exact recognition of every printed word; inspect the rendered physical page when that distinction matters. Search OCR uses CPU execution where Vision advertises support, with accurate recognition and language correction unchanged. Cancellation is cooperative and the shared PDF permit remains held until the awaited call returns, so other PDF operations may wait; there is no universal native-time deadline. The [validation record](Benchmarks/V2-VALIDATION.md) separates measured cancellation recovery, first-scan cost, cache reuse and remaining client qualification. Search returns only the matching page number. `read_file(format: pdf)` retrieves physical pages with exactly one text block and one bounded PNG image per page, preserving diagrams and non-text content for the model. Select one page with `page`, an ordered set with `pages`, or an inclusive range such as `page_range: "7-10"`; the selectors are mutually exclusive, default to page 1, and are capped at 20 pages per call.

`limit` defaults to 20 and is capped at 50. When `next_cursor` is present, repeat the same semantic criteria with that cursor (`limit` may change); every match from successfully examined content remains reachable until a response omits `next_cursor`. Coverage is repeated on every page and is independent of pagination. The cursor is bound to both the request and a deterministic fingerprint of the searchable corpus. If the vault changes between pages, the cursor is rejected as stale instead of silently skipping a result; restart the search from its first page.

Search locators contain no snippets, file content, scores or mutation revisions; bounded coverage categories describe isolated failures separately. Each complete encoded locator is limited to 4 KiB. If any locator in a source exceeds that ceiling, the source contributes no partial results and is reported as incomplete `file_limit` coverage; identifiers are never clipped. This discovery bound does not invalidate stored Canvas IDs or direct read selectors. Structured search output is capped at 256 KiB. Search discovers where information lives; `read_file` retrieves it and supplies the revision required for a later note update or delete.


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

The matrix and each format's create input and update modes come from one exhaustive backend catalog. Update schemas keep callable fields at the top level and use catalog-derived conditional rules to reject unsupported format/mode combinations: `replace` and `append` require `content`; `patch` requires 1–20 `replacements` objects containing `old_text` and `new_text`, and forbids `content`. MCP tool discovery projects that contract directly into the four CRUD schemas, and `VaultFileService` enforces the same create contract before dispatch, so advertised and accepted inputs cannot drift. Adding a format does not require a resource or a second frontend registry. Internal handler identities stay private. In `--read-only` mode, mutating tools disappear from discovery.

Format-specific CRUD behavior stays behind the four endpoints:

- HAR input must have a valid, duplicate-key-free HAR `log` structure, including `version`, `creator.name`, and `entries` (an empty entries array is valid). Malformed input returns corrective `INVALID_REQUEST` guidance without internal parser details. Authorization/cookie headers, cookies, URL user information, authentication parameters, and credential fields in JSON/form request bodies are redacted before Git persistence; reads validate the complete sanitized archive before returning a bounded text chunk.
- Privately snapshotted text writes reject high-confidence bearer, session, JWT, and provider-token patterns before persistence. Diagnostics identify the detector and line without repeating the credential; explicit redaction and documentation placeholders remain valid.
- Patch input must be a unified diff; reads validate the complete diff before returning a bounded text chunk.
- Logs default to the last 500 records, support bounded line ranges or revision-guarded byte pagination, reject a selected line window above the response ceiling, and can only be appended. A final newline terminates a record rather than adding an empty one; empty logs have zero records, consecutive delimiters preserve intentional blank records, and CRLF counts as one delimiter. Byte-window reads preserve the original bytes and exact revisions.
- JSON accepts any valid top-level JSON value, preserves its original representation, validates the complete document, and supports revision-guarded chunk reads plus replacement or exact text patches.
- CSV supports quoted fields, escaped quotes, embedded line breaks, and consistent column counts; reads and updates validate the complete table before returning or persisting bounded content.
- Canvas input is structurally validated without re-serializing it, so extension/plugin keys survive. Pass both `canvas_node_id` and `canvas_field` from a search hit to `read_file` for just that decoded field. Repeat both selectors and the same raw-file revision for continuation; `text_window` then describes the selected field, not the raw JSON. Empty existing fields remain valid.
- Images are decoded before import; PNG creation strips metadata/trailing payloads and caps the stored long edge. Image reads return inspected dimensions, byte size, and animation frame count/duration by default, without pixel encoding or image blocks. Add `render: true` to view a still image or up to eight sampled timed GIF frames. Rendering is opt-in per call, not a session setting; aggregate encoded frame bytes remain bounded before base64 expansion. The server cannot control how a client redisplays images already in its conversation history. PDF page reads retain their explicit text-plus-image contract; omit `render` for PDFs and other non-image formats.
- PDF reads return exactly bounded text plus a PNG image for each selected physical page. `page`, `pages`, and `page_range` provide single-page, ordered-set, and inclusive-range retrieval; content queries belong to `search_vault`.

### Metadata view

`read_file` defaults to `view: content`. Use `view: metadata` only when document facts are enough: Markdown returns bounded title, tags, word count, and outgoing local wiki/inline Markdown targets; PDF returns bounded title, author, physical page count, page labels, and flattened outline entries. Metadata mode returns no body text, page images, or snippets. Omit `max_bytes`, `byte_offset`, `expected_revision`, and log/PDF/Canvas content selectors; metadata uses its own fixed bounds. Incompatible fields are rejected by name, never silently ignored. Notes still return their exact revision so a later mutation can use the state that was inspected. `metadata.incomplete_fields` always lists any omitted or shortened fields (empty when none). Exact tags and link targets are returned whole or omitted; display titles/labels may be shortened with that indicator. Metadata keeps at most 256 tags and 512 distinct outgoing targets within 64 KiB, with separate scan-work bounds.

### Text continuation

Markdown, Canvas, patch, JSON, CSV, and sanitized HAR files are validated as complete documents but returned as bounded UTF-8 byte windows. The default `max_bytes` is 65,536 and the allowed range is 4–262,144. A first read normally omits `byte_offset`; every response includes `text_window.byte_offset`, `byte_count`, and `total_bytes`. If `next_byte_offset` is present, call `read_file` again with that offset and the exact `revision` from the previous response as `expected_revision`. Continuation fails if the file changed, an offset is outside the document or inside a UTF-8 scalar, or text selectors are combined with incompatible log/PDF selectors. Absence of `next_byte_offset` means the complete document has been returned—content is never silently truncated.

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
- **No caller-selected commands** — only a validated canonical Apple-signed Git executable, with programmatic argument arrays and no shell
- **Structural write boundaries** — `WritableFileTarget` cannot represent a path under `references/`
- **Soft deletes only** — files are never permanently deleted
- **Fixed Git snapshot identity** — callers cannot select commit messages; hooks and signing are disabled

See [SECURITY.md](SECURITY.md) for the full threat model, network-activity audit, dependency tree, and how to verify it all yourself.

## Architecture

```
Sources/SecondBrainMCP/
├── Frontend/                           # Public CLI and MCP API boundary
│   ├── Application/main.swift
│   ├── Configuration/                  # Argument parsing
│   └── MCP/
│       ├── MCPServerSetup.swift        # Transport lifecycle and tool dispatch
│       ├── PathMoves/                  # Atomic file-or-subtree move adapter
│       ├── Files/                      # CRUD and metadata schemas/adapters
│       └── Search/                     # Listing, content, and link-query schemas/adapters
├── Backend/                            # Internal behavior; never imports MCP
│   ├── Infrastructure/VaultRuntime.swift # Composition root and dependency injection
│   ├── Concurrency/                    # Reusable gates and vault access coordination
│   ├── PathMoves/                      # Validated atomic file-or-subtree movement
│   ├── Files/
│   │   ├── Ingress/                    # Stored-text request-to-bytes policy
│   │   ├── Operations/                 # Format-specific validation/transformation
│   │   ├── Routing/                    # Catalog, operation families, routed service
│   │   ├── Storage/                    # Generic snapshots, persistence, soft deletion
│   │   ├── Targets/                    # Validated readable/writable vault paths
│   │   ├── Transactions/               # Prepared persistence and Git sequencing
│   │   └── Validation/                 # Vault and external-source security
│   ├── Search/                         # Listing, atoms, link resolution, matching, pagination
│   ├── VaultVersioning/                # Sole Git subprocess boundary
│   └── Canvas/, HAR/, Media/, References/ # Specialized format processing
└── Shared/                             # Cross-boundary values and small utilities
    ├── Files/                          # CRUD, listing, metadata, and path-move contracts
    ├── Search/                         # Search and link-query request/result/service contracts
    ├── References/                     # Shared PDF navigation values
    └── Logging/                        # Shared stderr logger
```

### Layer and protocol boundaries

Solid arrows show runtime requests and data flow. Dashed arrows show composition or shared
coordination. The Shared nodes are protocols and values, not another orchestration layer.

```mermaid
flowchart TB
    Client["MCP client<br/>stdio JSON-RPC"]

    subgraph Frontend["Frontend — transport boundary<br/>Sources/SecondBrainMCP/Frontend"]
        direction LR
        Startup["Application + Configuration<br/>startup and CLI arguments"]
        Server["MCP/MCPServerSetup.swift<br/>server lifecycle and strict dispatch"]
        FileAdapter["MCP/Files<br/>CRUD and metadata schemas"]
        QueryAdapter["MCP/Search<br/>listing, content, and link-query schemas"]
        MoveAdapter["MCP/PathMoves<br/>file/subtree move schema"]
        Startup --> Server
        Server --> FileAdapter
        Server --> QueryAdapter
        Server --> MoveAdapter
    end

    subgraph Shared["Shared — stable protocol boundary<br/>Sources/SecondBrainMCP/Shared"]
        direction LR
        FilePort["Files<br/>CRUD and metadata contracts"]
        ListingPort["Files/FileListingService<br/>bounded file descriptors"]
        MovePort["Files/PathMoveService<br/>file/subtree move contract"]
        SearchPort["Search/VaultSearchService<br/>bounded atom locators"]
        LinkPort["Search/VaultLinkQueryService<br/>resolve, outgoing, backlinks"]
    end

    subgraph Backend["Backend — policy and execution<br/>Sources/SecondBrainMCP/Backend"]
        direction LR
        Runtime["Infrastructure/VaultRuntime<br/>composition root"]
        FileCore["Files<br/>routing, validation, storage, transactions"]
        QueryCore["Search<br/>listing, atoms, links, matching, bounded pagination"]
        MoveCore["PathMoves/VaultPathMoveService<br/>validated atomic file/subtree move"]
        Specialized["Canvas + HAR + Media + References<br/>format-specific processing"]
        Access["VaultAccessCoordinator<br/>shared reads / exclusive mutations"]
        Versioning["VaultVersioning<br/>sole Git boundary"]
    end

    Vault[("Vault filesystem<br/>notes / references / .trash")]
    Git[("Private Application Support<br/>Git snapshots")]

    Client --> Server
    FileAdapter --> FilePort --> FileCore
    QueryAdapter --> ListingPort --> QueryCore
    QueryAdapter --> SearchPort --> QueryCore
    QueryAdapter --> LinkPort --> QueryCore
    MoveAdapter --> MovePort --> MoveCore

    Runtime -. "constructs and injects" .-> FileCore
    Runtime -. "constructs and injects" .-> QueryCore
    Runtime -. "constructs and injects" .-> MoveCore
    Access -. "coordinates" .-> FileCore
    Access -. "coordinates" .-> QueryCore
    Access -. "coordinates" .-> MoveCore

    FileCore --> Specialized
    FileCore --> Vault
    QueryCore --> Vault
    MoveCore --> Vault
    FileCore --> Versioning
    MoveCore --> Versioning
    Versioning --> Git
```

The boundary rule is simple: Frontend understands MCP but not vault policy; Shared defines the
plain Swift contracts both sides agree on; Backend implements those contracts and owns all vault
behavior. Listing, content search, link queries, and path moves use narrow protocols because none
is atomic file CRUD.

### Catalog-driven CRUD

All four public file tools share one frontend pipeline. The backend catalog is the only place that
decides which operations and format-specific hooks exist.

```mermaid
flowchart TD
    Tools["create_file / read_file / update_file / delete_file<br/>Frontend/MCP/Files"]
    Port["FileCRUDService<br/>Shared/Files"]
    Service["VaultFileService<br/>Backend/Files/Routing<br/>safe targets, revisions, coordination"]

    Factory["FileFormatCatalogFactory<br/>exhaustive FileFormat registration"]
    TextFamily["StoredTextFileOperationFamily<br/>ordinary UTF-8 formats"]
    ImageFamily["ImageFileOperationFamily<br/>shared image behavior"]
    Explicit["Explicit bindings<br/>PDF and other exceptional behavior"]
    Catalog["FileFormatCatalog<br/>operation lookup by format"]

    Create["Create<br/>declared input + preparation hook"]
    Read["Read<br/>exact-content default<br/>optional special reader"]
    Update["Update<br/>generic edit engine<br/>declared modes + final validation"]
    Delete["Delete<br/>shared recoverable soft delete"]

    ReadAdmission["Format admission<br/>PDF permit before snapshot"]
    ReadLease["Shared read lease"]
    MutationLease["Exclusive mutation lease"]
    Store["VaultCRUDStore<br/>sole generic persistence component"]
    Executor["VaultMutationExecutor<br/>owns mutation sequencing"]
    Versioning["VaultVersioning"]
    Vault[("Vault filesystem")]
    Git[("Private Git snapshot")]
    Result["Awaited result<br/>mapped back to MCP"]

    Tools --> Port --> Service --> Catalog
    Factory -. "assembles at startup" .-> TextFamily
    Factory -. "assembles at startup" .-> ImageFamily
    Factory -. "assembles at startup" .-> Explicit
    TextFamily --> Catalog
    ImageFamily --> Catalog
    Explicit --> Catalog

    Catalog --> Create
    Catalog --> Read
    Catalog --> Update
    Catalog --> Delete

    Read --> ReadAdmission --> ReadLease --> Vault --> Result
    Create --> MutationLease
    Update --> MutationLease
    Delete --> MutationLease
    MutationLease --> Executor
    Executor -->|"1. persist prepared bytes"| Store --> Vault
    Executor -->|"2. await required snapshot"| Versioning --> Git
    Versioning --> Result
```

The operation families supply the common behavior. A catalog case declares only what differs:
creation validation or transformation, an exceptional read, allowed update modes, final-content
validation, or specialized append semantics. Delete is destructive but generic; HAR and log reads
are non-mutating but specialized. This is why specialization follows format policy rather than a
simple read-versus-write split.

Dependencies flow inward as `Frontend → Backend → Shared`. Frontend translates CLI/MCP
inputs into plain Swift values. Backend owns vault behavior, routing, processing, and persistence.
Shared contains only stable contracts or genuinely cross-boundary utilities; feature orchestration
does not belong there. Backend and Shared never depend on Frontend.

`VaultRuntime` is the backend composition root. `FileFormatDefinition` is the wiring point: each
concrete format registers only the operations it supports and binds those operations to reusable
functions. `VaultFileService` validates registered create contracts, routes requests, and supplies
read handlers with one immutable byte snapshot used for both content and revision. `TextFileIngress`
converts stored-text create requests into bounded inline bytes before their semantic handler; and
`VaultMutationExecutor` performs the prepared persistence and awaits any required vault snapshot.
Format handlers never load external text sources or write vault files; `VaultCRUDStore` is the sole
persistence component for the generic API. Writable targets cannot represent `references/`.

**Concurrency model:** one `VaultAccessCoordinator` is created per `VaultRuntime` and injected
through the `VaultAccessCoordinating` protocol. Shared leases let reads overlap. A mutation waits
for existing reads, then holds the exclusive lease through validation, preparation, filesystem
persistence, and Git snapshot. Once a mutation is queued, later reads wait behind it. Independent
MCP processes use shared/exclusive modes on the same advisory lock file. OS scheduling does not
promise strict FIFO ordering between separate processes, so mixed old/new hosts must be fully
restarted after an upgrade. Direct PDF content and metadata reads acquire their shared PDF permit
before the vault read lease and byte snapshot; queued requests retain no PDF snapshot. Search captures
under the vault read lease, releases that lease, then acquires the same PDF permit before loading a
private PDF snapshot. Extraction never reacquires the vault lease.

Queued cancellation performs no mutation. Cancellation is checked again before prepared persistence
starts; once persistence starts, the persistence-and-snapshot chain finishes before the exclusive
lease is released. Exact-byte revisions reject stale cooperating edits, and the store rechecks bytes
immediately before persistence. Applications that ignore the MCP lock can still write inside the
final compare-to-rename window because filesystem path replacement has no universal cross-application
compare-and-swap. If a response is lost, callers must read the target and decide from its current
state whether another mutation is necessary.
