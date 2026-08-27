# Migrating from v0.7.1 to v2

This guide compares the last supported public release, the annotated `0.7.1` tag, with the
v2 rewrite on `main`. It treats capabilities—not tool count—as the compatibility boundary.

v2 intentionally replaces specialized note, Canvas, reference, image, Git, and discovery tools
with eight composable tools:

- `list_files`
- `search_vault`
- `query_links`
- `create_file`
- `read_file`
- `update_file`
- `delete_file`
- `move_path`

The simplification is deliberate. A missing v0.7.1 capability should return only when it has
real user value and cannot be expressed safely through those primitives. It should not return
merely to restore the old number of tools.

## Upgrade checklist

1. Make a normal backup of the vault and review its Git status before changing the configured
   executable. Do not delete unrelated uncommitted files to make the upgrade work.
2. Build v2 in release mode and configure every MCP client to launch the stable
   `.build/release/second-brain-mcp` symlink, not an architecture-specific build product.
3. Keep `--vault <path>` and, when wanted, `--read-only`. The old `--extensions` and
   `--log-level` arguments are accepted only as ignored legacy/unknown arguments; they no longer
   change behavior. Supported formats now come from the server's explicit format catalog.
4. Fully quit and relaunch every application or agent host that can start this MCP. A reconnect
   inside one application is insufficient when another old host is still running. v0.7.1 does not
   participate in v2's cross-process vault lock, and clients commonly cache discovered tools.
5. Confirm that discovery shows the eight v2 tools, or four tools in `--read-only` mode
   (`list_files`, `search_vault`, `query_links`, and `read_file`; mutation tools are hidden).
6. Continue large UTF-8 reads with `text_window.next_byte_offset` as `byte_offset` and the
   preceding exact `revision` as `expected_revision`. The default response is 64 KiB; absence of
   `next_byte_offset` means the document is complete.
7. Change workflows that update, delete, or move one file: call `read_file`, retain its opaque
   `revision`, then pass it as `expected_revision`. On a conflict—or after a lost mutation
   response—read the current state and reconsider instead of retrying blindly.
8. Keep `references/` read-only. v2 structurally prevents writes there; this is not controlled
   by a permissive runtime flag.
9. Do not remove a leftover vault-local `.secondbrain-mcp/` directory during the upgrade.
   v0.7.1 attempted to migrate its audit/cache data to
   `~/Library/Application Support/SecondBrainMCP/<vault-hash>/`; v2 leaves any obsolete remnants
   untouched. Retain them until rollback and old-audit needs have expired, then review them
   manually.

The vault's user-content layout remains `notes/`, `references/`, and recoverable
`.trash/` content. No note or reference content conversion is required.

## What v0.7.1 actually exposed

The v0.7.1 README says “17 MCP tools,” but the tagged implementation registers **29 tools**.
It also registers **four MCP resources**. The implementation is the source of truth for this
comparison.

Status meanings:

| Status | Meaning |
|---|---|
| **Direct** | The v2 generic tool preserves the important externally observable capability. |
| **Composable / weaker** | A v2 workflow covers the core use case, but needs more calls or returns less structured information. |
| **Removed** | v2 intentionally omits the capability because it adds ceremony, weakens a boundary, or belongs in an operator workflow rather than an agent tool. |

### Tools

| v0.7.1 tool | v2 status | v2 workflow and semantic difference |
|---|---|---|
| `read_note` | **Direct** | `read_file(format: markdown)` returns a bounded note window and an exact-byte revision; follow `next_byte_offset` with that revision until complete. |
| `read_notes` | **Composable / weaker** | Call `read_file` for each path, preferably concurrently. There is no one-call batch, combined summary, or per-item error envelope. |
| `list_notes` | **Composable / weaker** | `list_files(area: notes, formats: [markdown])` enumerates paths with directory, recursion, and format filters plus size/modified-time facts, using stable path order rather than newest-first order. |
| `get_note_metadata` | **Direct** | `read_file(format: markdown, view: metadata)` returns bounded title, tags, word count, outgoing local wiki/inline Markdown targets, filesystem facts, and the note revision without body content. |
| `search_notes` | **Composable / weaker** | `search_vault(location: notes)`, then `read_file`. Search is bounded and paginated but returns locators, not snippets or scores. |
| `read_canvas` | **Composable / weaker** | `read_file(format: canvas)` exposes revision-consistent raw JSON windows or the decoded `canvas_node_id`/`canvas_field` selected by search. The old node/edge summary and per-node warning projection are not returned. |
| `list_canvas` | **Composable / weaker** | `list_files(area: notes, formats: [canvas])` enumerates Canvas paths and filesystem facts, but not node-type counts. |
| `search_canvas` | **Direct** | `search_vault(location: notes)` returns exact `canvas_node_id` and `canvas_field` locators for semantic node fields, without snippets. |
| `list_attachments` | **Composable / weaker** | `list_files` enumerates every registered readable format, but intentionally excludes unknown binary escape hatches. |
| `resolve_link` | **Direct** | `query_links(direction: resolve)` handles aliases, embeds, explicit and extensionless paths, ambiguity, and optional source proximity. |
| `find_backlinks` | **Direct** | `query_links(direction: backlinks)` resolves targets per source context and defaults to source/target groups with occurrence counts. Use `group_by: occurrence` and `source_path` to inspect one group. |
| `create_note` | **Direct** | `create_file(format: markdown)`; parent directories and absent frontmatter are handled. |
| `update_note` | **Direct** | `update_file(format: markdown)` supports replace, append, and exact patch, with required optimistic revision checking. |
| `move_note` | **Direct** | `move_path(kind: file)` performs an atomic, no-follow, no-clobber rename with explicit format and exact source revision. |
| `move_notes` | **Removed** | No atomic batch file-move contract exists. Repeating CRUD calls does not preserve the old all-or-nothing behavior. |
| `delete_note` | **Direct** | `delete_file(format: markdown)` performs revision-checked recoverable soft deletion. |
| `create_canvas` | **Direct** | `create_file(format: canvas)` validates structure while preserving extension/plugin keys. |
| `update_canvas` | **Direct** | `update_file(format: canvas, mode: replace)` with revision checking. |
| `delete_canvas` | **Direct** | `delete_file(format: canvas)` performs revision-checked soft deletion. |
| `delete_attachment` | **Composable / weaker** | `delete_file` deletes a registered, deletable format under `notes/`. v0.7.1 could delete any non-note/non-Canvas attachment, including unknown binary formats. |
| `add_image` | **Direct** | `create_file(format: png, source: ...)` decodes, cleans, bounds, and stores an external image without mutating the source. |
| `note_history` | **Removed** | Git still records recovery snapshots, but no MCP history query exists. |
| `revert_note` | **Removed** | No MCP restore operation exists, and v2 snapshots may coalesce several agents' note changes. |
| `vault_changelog` | **Removed** | No MCP repository-wide changelog query exists. |
| `list_references` | **Composable / weaker** | `list_files(area: references)` provides paths, formats, sizes, and modified times; call `read_file(view: metadata)` only for selected PDFs that need title, author, page count, labels, or outline. |
| `read_reference` | **Direct** | `read_file(format: pdf)` supports physical pages/ranges and a separate metadata view with title, author, page count, page labels, and bounded outline; compose `search_vault` for passage discovery. |
| `search_references` | **Composable / weaker** | `search_vault(location: references)`, then `read_file`. v2 adds per-page OCR and stable pagination but returns locators rather than snippets/reference metadata. |
| `get_reference_metadata` | **Direct** | `read_file(format: pdf, view: metadata)` returns the bounded metadata-only projection without page text or images. |
| `read_image` | **Direct** | `read_file` covers PNG/GIF plus JPEG, WebP, HEIC, TIFF, and BMP aliases, with bounded decoding and animated-GIF sampling. |

### Resources

v2 advertises no MCP resources. Tool discovery and the explicit format schemas replace capability
documentation, but they do not reproduce these data resources.

| v0.7.1 resource | v2 status | Missing behavior |
|---|---|---|
| `secondbrain://index` | **Removed** | Full note path/title/tag index. |
| `secondbrain://recent` | **Removed** | Notes selected by filesystem modification time over the last seven days. Created-date search is not equivalent. |
| `secondbrain://tags` | **Removed** | Aggregate tag names and note counts. |
| `secondbrain://references` | **Removed** | Full PDF path/title/author/page-count index. |

## Old-to-new workflow map

| Goal | v0.7.1 | v2 |
|---|---|---|
| Discover relevant note content | `search_notes` returned snippets | `search_vault(location: notes)` returns bounded locators; read selected paths with `read_file`. |
| Read one note | `read_note` | `read_file(format: markdown)`. Follow revision-guarded `next_byte_offset` values until absent; keep the revision if a mutation may follow. |
| Read several known notes | `read_notes` | Issue independent `read_file` calls; client-side concurrency preserves the compact model but intentionally has no batch envelope. |
| Create/update/delete a note | Specialized note tools | `create_file`, `update_file`, or `delete_file` with `format: markdown`; update/delete require a prior revision. |
| Apply a precise text edit | Replace/append only | `update_file(mode: patch)` for supported textual formats, with a unique exact match and revision. |
| Work with Canvas | Specialized Canvas tools | Use generic CRUD with `format: canvas`; `search_vault` returns exact matching node IDs and fields. |
| Find and read a PDF passage | `search_references` or `read_reference(query:)` | `search_vault(location: references)`, then `read_file(format: pdf, page: ...)`. |
| Read several PDF pages | Page/range/book-page selectors | Use `page`, ordered `pages`, or `page_range`; use `view: metadata` for page labels and the bounded outline. |
| Import an image | `add_image` | `create_file(format: png, source: ...)`. |
| Import a short animation | Not available | `create_file(format: gif, source: ..., transform: video_to_gif)`. |
| Move a complete notes folder | Repeated file moves | `move_path(kind: directory)` performs one validated atomic subtree rename and one snapshot request. |
| Move one file or an arbitrary batch | `move_note` / `move_notes` | `move_path(kind: file)` covers one revision-guarded atomic file move. Arbitrary batches remain intentionally removed. |
| Resolve links or find backlinks | `resolve_link` / `find_backlinks` | `query_links` provides bounded resolve, outgoing, and backlinks directions with structured ambiguity. |
| Inspect or restore Git history | Three Git-facing tools | Use Git outside MCP; model-visible history/restore stays intentionally outside the v2 contract. |
| Browse all files or metadata | Listing tools and resources | `list_files` enumerates registered files; `read_file(view: metadata)` inspects selected Markdown or PDF documents without returning content. |

## Capabilities v2 adds over v0.7.1

| New v2 capability | What it changes |
|---|---|
| Explicit catalog-driven formats | One discoverable contract supports Markdown, Canvas, HAR, patch/diff, log, JSON, CSV, PNG, GIF, JPEG, WebP, HEIC, TIFF, BMP, and PDF instead of note/reference-specific registries. |
| Bounded revision-guarded text reads | Complete UTF-8 documents are validated, then returned in explicit 64 KiB windows by default. Continuations require the prior exact revision, preserve Unicode scalar boundaries, and never silently truncate. |
| Exact-byte revisions | Reads return an opaque revision; update, delete, and file moves compare it immediately before mutation and reject stale cooperative edits. v0.7.1 had no public compare-and-swap boundary. |
| Shared/exclusive vault coordination | Independent reads overlap; queued writers get preference and hold exclusivity through validation, persistence, and Git snapshotting. |
| Cross-process advisory locking | Cooperating v2 MCP processes coordinate through vault-specific locks. v0.7.1 processes did not share this boundary. |
| Atomic path movement | `move_path` performs a validated, no-follow, no-clobber file or subtree rename under one mutation lease; file moves preserve exact bytes and revision. |
| Bounded composable discovery | `list_files`, `search_vault`, and `query_links` are capped, deterministic, request/corpus-bound, and reject stale or forged continuation. |
| Search scope and truthful completeness | `directory` and `formats` exclude unrelated content before opening. Isolated bad files preserve healthy results but set `coverage.complete: false`; an incomplete empty result is not proof of absence. Traversal failures and file/entry/work limits abort safely. |
| PDF OCR and revision cache | PDF search prefers embedded text and uses Vision OCR when absent; page text is cached outside the vault by exact revision. |
| Ordered PDF reads and metadata | One call can request bounded physical pages with text/PNG rendering; metadata view returns title, author, page count, labels, and bounded outline without page content. |
| Structured format validation and consumable Canvas locators | JSON, CSV, HAR, Canvas, unified diffs, images, and updates are validated without silent repair. Canvas search returns a node/field that `read_file` can read directly, with the full raw-file revision. |
| Local links and grouped backlinks | Wiki and inline Markdown links/images share grammar across metadata and graph queries; external URLs/code are excluded, reference-style links remain unsupported. Backlinks group repeated occurrences and allow source-specific drill-down. |
| Explicit metadata incompleteness | Bounded facts name any omitted/shortened fields. Exact tags and link targets are never replaced by clipped identifiers. |
| Credential protection before Git | High-confidence secrets in textual writes are rejected without echoing the secret; known HAR credential fields are sanitized before persistence. |
| Safer external media ingress | External sources are canonicalized, regular-file-only, size-capped, decoded in-process, and never moved, edited, or deleted. |
| HAR capture support | Valid HAR documents can be stored after targeted credential redaction and read back as complete sanitized JSON. |
| Log-specific behavior | Logs support bounded tail/range reads and append-only mutation. |
| Video-to-GIF import | A bounded external video can be converted to a GIF through the generic create contract. |
| Stronger mutation completion semantics | Queued cancellation does no work; once persistence starts, persistence plus required versioning completes before the exclusive lease is released. |
| Resilient startup recovery | MCP discovery and reads become available before pending Git recovery completes; a recovery failure blocks mutations without disconnecting reads. |
| Narrower Git execution boundary | Only `/usr/bin/git` is launched, inherited `GIT_*` redirection is removed, diagnostics are bounded, hooks are disabled for commits, and signing is disabled. |

## Git, audit, and internal-data changes

| Area | v0.7.1 | v2 |
|---|---|---|
| Commit meaning | Usually one `[SecondBrainMCP]` commit per specialized mutation, with a path/action-derived subject. | A commit is a recoverable notes-tree state named `Vault snapshot`. Concurrent/pending changes may coalesce, so it is not an agent or mutation ownership record. |
| Git failure handling | Mutation handlers commonly attempted the follow-up commit best-effort; Git failure was not a reliable transaction result. | Persistence and the required snapshot are one awaited responsibility. Snapshot failure is returned explicitly, even when filesystem persistence already occurred. |
| Git scope | Startup could stage the complete repository, and specialized operations staged their selected paths. | Dirty checks, staging, and commits are scoped to `notes/`; `git commit --only -- notes` preserves staged entries outside that tree, including references. |
| Git extension points | Used the user's normal Git execution context. | Commit hooks and GPG signing are disabled for server snapshots; inherited `GIT_*` variables cannot redirect the repository or command behavior. |
| Public history | `note_history`, `revert_note`, and `vault_changelog`. | No history or restore MCP tools. Use Git directly as the intentional operator recovery boundary. |
| Audit trail | An append-only audit log recorded read/search/mutation operation lines. In the 0.7.1 code it lived under the per-vault Application Support directory after migration. | No separate operation audit log. Git records changed notes states, not reads, searches, callers, or one-to-one operations. |
| Private data | PDF cache, audit log, and extraction lock under a hashed Application Support directory; startup attempted migration from vault-local `.secondbrain-mcp/`. | Hashed Application Support storage contains locks and derived search/PDF data; the derived search directory is enforced as owner-only `0700`. Obsolete vault-local data is preserved untouched, and no new audit log is created. |

A v2 Git history therefore cannot be interpreted as the old operation ledger. If caller identity,
read/search auditing, or one-click per-file restore is required, that must be designed explicitly
rather than inferred from snapshots.

## Resolved v2 product decisions

The release keeps only capabilities that reduce agent round trips or prevent unsafe multi-call
workflows. Specialized aliases and operator-facing ceremony remain intentionally removed.

| Capability | v2 decision | Agent-facing reason |
|---|---|---|
| Bounded file enumeration | **Included** as `list_files` | Lets an agent discover paths without guessing a search term or reading content. |
| Metadata-only inspection | **Included** as `read_file(view: metadata)` | Avoids full Markdown/PDF reads when only title, tags, counts, links, or navigation facts are needed. |
| Batch reads | **Removed** | Parallel bounded `read_file` calls are composable; a batch envelope adds error and byte-budget ceremony without measured benefit. |
| Atomic file and directory moves | **Included** as `move_path` | Reorganization is one revision-checked no-clobber mutation, avoiding unsafe read-create-delete sequences. Atomic batch moves remain removed until measured usage justifies their transaction semantics. |
| Link resolution and backlinks | **Included** as `query_links` | Resolves Obsidian ambiguity and graph navigation directly without broad content searches. |
| Version history and restore tools | **Removed** | Git remains the operator recovery boundary; model-visible history would misrepresent coalesced snapshots and enlarge mutation risk. |
| PDF navigation metadata | **Included** in `read_file(view: metadata)` | Gives agents bounded title, author, page-count, labels, and outline facts without page decoding. |
| Structured Canvas hits and reads | **Included** in `search_vault` and `read_file` | Exact node/field selectors avoid paging through unrelated raw Canvas JSON to consume a hit. |
| Arbitrary attachment management | **Removed** | Only registered, validated formats cross the public boundary; an unrestricted binary escape hatch would weaken size, media, revision, and credential policy. |
| MCP resources | **Removed** | The bounded tool schemas are the single discovery contract, avoiding parallel resource implementations and stale indexes. |
| Operation auditing | **Removed** | Git recovery plus bounded stderr diagnostics are sufficient; a durable access log would retain sensitive read/search history without improving agent work. |
| `--extensions` customization | **Removed** | One explicit format catalog keeps extension/content agreement and discovery stable. |
| `--log-level` | **Removed** | Current bounded stderr lifecycle/error diagnostics are adequate and keep stdout exclusively JSON-RPC. |

### Release-safety gate resolved separately from parity

Large complete text reads in v0.7.1 were not a capability worth preserving: a response near the
storage ceiling could exceed a client's practical context and appear stuck. v2 validates the
complete UTF-8 document but returns explicit 64 KiB windows by default, with a 256 KiB maximum,
UTF-8-safe boundaries, `text_window` continuation facts, and an exact-revision requirement for every
nonzero continuation offset. This bounds document-text responses without lowering the supported
storage limits; images, locators and protocol framing have separate limits.

The parity decisions above remain independent. Do not restore a missing legacy capability merely
because bounded reading changed the generic tool schema.
