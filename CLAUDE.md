# SecondBrainMCP

A local MCP server in Swift that gives Claude Desktop and Claude Code read/write access to a
Markdown note vault and **read-only** access to a PDF reference library. It runs as a subprocess
speaking JSON-RPC over stdio, and every note write is auto-committed to git.

The codebase favors **clear boundaries and structural safety over cleverness**: security is
enforced by architecture (not runtime flags), there are zero third-party dependencies beyond the
MCP SDK, and every rule below is load-bearing and covered by tests. **New here?** Read
[Critical Rules](#critical-rules--do-not-violate) and
[Layering & guardrails](#layering--guardrails--the-walls-that-keep-it-clean) first — they're the
walls everything else leans on.

This file is for working *in* the code. `README.md` is the user-facing doc (setup, full tool and
resource reference).

## Stack

- Swift 6.2 (strict concurrency), macOS 26 (Tahoe), Xcode 26
- MCP SDK: `modelcontextprotocol/swift-sdk`, pinned `from: "0.12.0"` (see `Package.swift`)
- Transport: `StdioTransport` (stdin/stdout JSON-RPC)
- PDF: `PDFKit` (system framework, zero deps) — page→JPEG rendering + text extraction
- Subprocesses: `/usr/bin/git` and `/usr/bin/grep` only (see Rule 4)

## Commands

```bash
swift build                            # Debug build
swift build -c release                 # Release → .build/release/second-brain-mcp
swift test                             # Full suite — keep it green
swift test --filter PathValidatorTests # The security suite — this one must never fail
```

Run by hand: `second-brain-mcp --vault <path> [--read-only] [--extensions md,markdown] [--log-level info]`

**Binary path / Swift 6.4 layout change:** point any MCP client at the `.build/release/second-brain-mcp`
*symlink*, never the arch-specific `.build/<triple>/release/...` path. Swift 6.4 flipped SwiftPM's default
build system from `native` (output: `.build/<triple>/release/`) to `swiftbuild` (output:
`.build/out/Products/Release/`); the `.build/release` symlink tracks the current layout under both, so it
survives toolchain upgrades. A config pinned to the old arch path silently launches a stale binary after a
Swift upgrade (the build succeeds elsewhere) — and the client must be fully relaunched to pick up tool changes.

There's no CI, linter, or formatter — **`swift test` is the dev loop**, and you match the
surrounding style. Running the binary directly only proves startup + git-init; it then blocks
waiting for a JSON-RPC client on stdin, so real behavior is verified through tests.

## Architecture

```
Sources/SecondBrainMCP/
├── main.swift                  # Entry: SIGPIPE ignore, parse args, git ensure, start server
├── Config/ServerConfig.swift   # CLI args → Sendable config struct
├── Server/MCPServerSetup.swift # Server init, handler wiring, all tools + resources
├── Core/
│   ├── VaultManager.swift      # actor — sandboxed note I/O (read/create/update/move/delete)
│   ├── GitManager.swift        # actor — serialized git via /usr/bin/git
│   ├── SearchEngine.swift      # Sendable struct — on-demand /usr/bin/grep, no in-memory index
│   ├── ReferenceManager.swift  # Sendable struct — PDF reads, ZERO write methods by design
│   ├── ReferenceCache.swift    # enum namespace — lightweight on-disk search cache
│   ├── PDFPageRenderer.swift   # struct/static — page→JPEG, outline + page-label extraction
│   ├── PDFTextExtractor.swift  # struct/static — PDFKit text extraction + in-doc search
│   ├── PathValidator.swift     # struct/static — path-traversal prevention (CRITICAL)
│   ├── MarkdownParser.swift    # struct/static — YAML frontmatter + link extraction
│   ├── VaultEnumerator.swift   # struct/static — shared list_* file walk (clean paths, skips dotfiles/.gitkeep)
│   ├── AttachmentManager.swift # Sendable struct — list_attachments (non-note/canvas files under notes/)
│   ├── CanvasManager.swift     # actor — sandboxed .canvas CRUD + list (notes/, soft-delete, git)
│   ├── CanvasModel.swift       # enum/static — JSON Canvas 1.0 validation (validate, never re-serialize)
│   ├── ImageManager.swift       # Sendable struct — PNG read policy (caps, pass-through vs downscale, bomb guard)
│   ├── ImageEncoding.swift     # protocol — platform seam for image inspect/encode
│   ├── CoreGraphicsImageEncoder.swift # macOS ImageIO impl of ImageEncoding (#if canImport(ImageIO))
│   └── DataPaths.swift         # internal data path resolution (see "Where data lives")
└── Logging/AuditLogger.swift   # actor — append-only operation log

Tests/SecondBrainMCPTests/      # PathValidator (exhaustive — the security backbone),
                                # VaultManager, MarkdownParser, SearchEngine, GitManager,
                                # Canvas (model + manager), ImageManager (+ encoder).
```

**Concurrency:** actors for mutable state + I/O (VaultManager, GitManager, AuditLogger);
Sendable structs for stateless concurrent work (ReferenceManager, SearchEngine, ServerConfig);
structs/enum with only static methods for pure logic (PathValidator, MarkdownParser,
PDFPageRenderer, PDFTextExtractor, ReferenceCache). No data races by construction.

### Layering & guardrails — the walls that keep it clean

Dependencies flow one way: `main → Server → Core → (Foundation/PDFKit)`. These boundaries are
what stop a growing app from turning into spaghetti — protect them:

- **The MCP boundary is exactly one file.** Only `MCPServerSetup.swift` imports `MCP` or touches
  `Tool` / `CallTool` / `MCPError`. Core managers speak plain Swift — return values and thrown
  errors — and know nothing about the protocol. That's what keeps Core unit-testable and the
  transport swappable. **Never `import MCP` in `Core/`.**
- **`MCPServerSetup.swift` is the god-file risk** — by far the largest file in the repo. Keep it
  *thin*: tool schemas, dispatch, param parsing, result formatting, nothing else. If a `handleXxx`
  grows past "parse args → call a manager → format the result," the logic belongs in a Core type.
  When the file gets unwieldy, split tool definitions / handlers into extensions in their own files
  before piling on more.
- **One type per file, one responsibility.** A new capability is a new `Core/` type — not a method
  bolted onto an unrelated manager, not inline in a handler. Core types are the unit of testing.
- **All filesystem access goes through a `PathValidator`-gated Core manager.** No `FileManager`
  calls in handlers (it's zero today — keep it zero). One path gate, never two.
- **No third `Process()` site** beyond git and grep (Rule 4). Prefer in-process work; if you truly
  can't, make it a deliberate, reviewed design call.

## Critical Rules — do not violate

### 1. Never write to stdout
Stdout *is* the JSON-RPC transport. A stray `print()` corrupts the protocol stream. Log to stderr
only (`fputs(..., stderr)` / the `log()` helper in `main.swift`).

### 2. Path security is non-negotiable
Every note file operation goes through `PathValidator.resolve(...)`, which rejects absolute paths,
pre- and post-screens for `..` (incl. percent-encoded / Unicode dots), resolves symlinks, and
asserts containment within the vault root (a trailing-slash prefix check blocks `/vault-evil` vs
`/vault`). Note ops *also* require a literal `notes/` prefix. If a path escapes, **throw
immediately** — no fallback. `PathValidatorTests` must stay green; if it fails, nothing else matters.

### 3. Write boundaries are structural, not flag-based
`ReferenceManager` has **zero** write methods — `references/` is read-only by architecture, not a
runtime check. Keep it that way.

| Area | Read | Write | Move | Delete |
|------|------|-------|------|--------|
| `notes/` | ✓ | ✓ | ✓ | ✓ (soft only) |
| `references/` | ✓ | ✗ | ✗ | ✗ |
| internal data | internal | internal | ✗ | ✗ |

### 4. No arbitrary shell execution
Only `/usr/bin/git` (via `GitManager`) and `/usr/bin/grep` (via `SearchEngine`), always with
programmatically built argument arrays and `--` guards. Never interpolate user input into args.
Commit messages and refs are sanitized to a safe character allowlist.

### 5. Soft deletes only
`delete_note` moves to `.trash/<ISO-timestamp>_<filename>`. Never `removeItem` user content.

### 6. Git auto-commit on every write
`create/update/move/delete` each trigger a `[SecondBrainMCP]`-prefixed commit.
- patch-mode `update_note`: skip the commit if all patches were no-ops.
- deletions: use `commitDeletion()` (`git add -A` on the parent dir) — handles macOS
  case-insensitive index mismatches.
- moves: use `commitMoves()` (stages source deletion + dest addition); batch moves = one commit.

## Conventions & design intent

The *why* behind the structure — follow these when adding code:

- **Reject, don't sanitize.** Hostile input (bad paths, weird refs) is thrown, never "fixed";
  sanitization is where security bugs hide. The lone exception is git commit messages/refs, filtered
  to an allowlist *because* they're already inside the trust boundary.
- **No `try?` in security-sensitive paths.** Handle the error or propagate it — a swallowed error
  once silently dropped a git commit (the case-insensitive delete bug).
- **Let the compiler prove safety.** `actor` for mutable state / serialized I/O, static `struct`/`enum`
  for pure logic. Don't escape the model with `@unchecked Sendable`.
- **Zero third-party deps beyond the MCP SDK.** Add one only when building it yourself clearly costs
  more — this is why CLI parsing is a hand-rolled loop, not swift-argument-parser, and search is grep,
  not SQLite FTS. (Reach for FTS only if grep latency becomes a real problem.)
- **No premature abstraction.** A `switch` over the tools is the right altitude — no tool-protocol
  hierarchy or plugin system at this scale.
- **Fail fast at startup, degrade gracefully at runtime.** Bad config → exit with a clear stderr
  message. One corrupt PDF → error its own request, never take down the server.
- **Errors:** each Core type nests `enum XError: Error, CustomStringConvertible`. Managers `throw`;
  handlers catch and return `CallTool.Result(content: [.text(...)], isError: true)` — never throw an
  expected failure (missing file, bad param, not found) to the client.
- **Tests use temp dirs** and clean up after themselves; none touches a real vault or depends on
  another test's ordering.
- **`///` comments explain *why*, not what;** `// MARK: -` divides a file into sections.
- **Repo commits use Conventional Commits** (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
  `chore:`) — distinct from the `[SecondBrainMCP]` prefix the server writes into a user's vault (Rule 6).

## Adding or changing a tool

A tool is wired across four spots in `MCPServerSetup.swift` — miss one and it half-works. To add
`foo_note`:

1. **`buildToolList()`** — append a `Tool(...)` with `inputSchema` and `annotations`. If it writes,
   put it inside the `if !config.readOnly { }` block so read-only mode hides it.
2. **`handleToolCall()`** — add the name→`AuditLogger.Operation` mapping in the `auditOp` switch,
   AND a `case "foo_note":` in the dispatch switch.
3. **Write `handleFooNote(params:...) -> CallTool.Result`** — `guard` each required param (return an
   `isError` result, don't throw), call the manager, format the output.
4. **Writes only:** trigger the matching `GitManager` commit (`commitChange` / `commitMoves` /
   `commitDeletion`). Reads need nothing extra.
5. Add a test. New domain logic goes in a `Core/` type, not in the handler.

Tool conventions: names are `snake_case`; always supply `inputSchema` (use `{"type":"object"}` even
for zero-param tools) and `annotations` (mark reads `readOnlyHint: true` so clients skip
confirmation). Handlers return plain `.text` / `.image` content — `structuredContent` is not used.

## Where data lives

**User content lives in the vault:** `notes/` (git-tracked), `references/` (gitignored), optional
`INSTRUCTIONS.md` (appended to the server's instructions), plus `.trash/` and `.git/`.

**MCP-internal data lives OUTSIDE the vault** at
`~/Library/Application Support/SecondBrainMCP/<sha256-of-vault-path>/` — see `DataPaths`. This was a
deliberate fix: keeping it in-vault made iCloud create corrupted `" 2"` / `" 3"` duplicate dirs and
hang grep. `DataPaths.migrateFromVaultIfNeeded()` migrates the old in-vault `.secondbrain-mcp/`
layout on startup. To force a PDF cache rebuild, delete that external `<vault-hash>/cache/references/`
dir and restart.

Server logs (stderr) are captured by Claude Desktop at
`~/Library/Logs/Claude/mcp-server-second-brain.log`.

## PDF subsystem

- `read_reference` returns **dual content per page**: extracted text (`.text`) + a JPEG render
  (`.image`). Text is fast and accurate; the image catches diagrams, equations, and scans. Defaults
  to 5 pages, **hard cap 20**. Render tuning (DPI, JPEG quality, max dimension) lives in
  `PDFPageRenderer.RenderConfig.default`.
- Navigation: `page` (physical, 1-indexed), `book_page` (printed label, e.g. "42"/"xii"),
  `page_range`, or `query` (full-document PDFKit search within that one PDF). The outline (bookmarks)
  and page labels come back on every call.
- `handleReadReference` races the work against a 60s timeout (`withThrowingTaskGroup`) so a corrupt
  PDF errors instead of hanging.
- **Search cache is tiered** (`ReferenceCache`): short PDFs cache full text, long ones cache the
  first chunk of pages + outline chapter titles (thresholds: `shortPDFThreshold` / `tocPages`).
  `search_text.txt` uses `--- Page N ---` markers so `SearchEngine` resolves a hit's page number.
  Bump `CacheMetadata.currentVersion` to force every cache to rebuild after a format change.
- Cache builds lazily ~1s after startup in a background `Task`: per-PDF `autoreleasepool`, an
  `flock()` lock so only one server instance builds, and an RSS safety valve that stops early and
  resumes next restart. **PDFs added while running aren't indexed until restart.**

## Gotchas

- **SIGPIPE must stay ignored** (`signal(SIGPIPE, SIG_IGN)` in `main.swift`) — Claude Desktop closing
  the pipe would otherwise silently kill the process.
- **PDFKit pages are 0-indexed**; users and tools are 1-indexed — convert at the boundary.
- **Case-only renames** (`Foo.md` → `foo.md`) fail on case-insensitive APFS; `VaultManager` detects
  them (`source.lowercased() == destination.lowercased()`) and does a temp-file two-step with rollback.
- **Batch moves** validate ALL before executing ANY, reject source/dest overlap, and roll back on
  partial failure (VaultManager is an actor → serialized).
- **Cache date comparison uses whole-second granularity** — `JSONEncoder` truncates APFS nanosecond
  `Date` precision; compare via `Int(timeIntervalSinceReferenceDate)`.
- **`references/` is hardcoded to `.pdf`**; `notes/` extensions are `--extensions`-configurable.
- **Canvas writes are lossless on purpose.** `CanvasModel.validate` only *decodes to prove* the JSON is well-formed JSON Canvas (unique node ids, edges reference existing nodes, valid enum/color values) — it is **never re-serialized**. `create`/`update_canvas` write the caller's **original bytes**, so plugin-added keys outside the 1.0 spec survive. Don't "round-trip through the model" — that would drop those keys.
- **All `list_*` enumeration goes through `VaultEnumerator`.** It builds clean vault-relative paths (a trailing-slash `directory` used to yield `notes//foo`) and skips dotfiles / `.gitkeep.md` placeholders / hidden dirs (any path component starting with `.`). `list_notes` and `list_canvas` both ride on it — add new listers there, not with a fresh `FileManager` walk. It does *not* hide `_`-prefixed dirs (that's user content, e.g. `_attachments`).
- **Canvas validates structure, not external links.** `CanvasModel.validate` rejects dangling **edge→node** references (intra-document structural integrity) but a **file-node→file** reference is an extra-document soft link the spec and Obsidian tolerate — so it's *not* existence-checked on write. `read_canvas` surfaces a broken one as a non-blocking `⚠ file not found` instead (see `CanvasManager.fileNodeWarning`). Don't "fix" this asymmetry by rejecting file-nodes on write — it would reject canvases Obsidian accepts.
- **`read_image` transforms only when it must.** A still within the model's native resolution (long edge ≤ 2576px) whose format the API accepts natively (png/jpeg/gif/webp) is passed through **byte-for-byte** with its own mime type — re-encoding does nothing for readability, the only reason to transform is size. Oversized stills, and formats the API won't accept (heic/tiff/bmp), are re-encoded to PNG. The **decode-bomb guard is `ImageEncoding.inspect`**: it reads dimensions + frame count *without* decoding, and `ImageManager` rejects >50 MP before any decode. Keep that order — inspect, reject, only then decode.
- **Animated GIFs return a frame *bundle*, not one image.** The model can't perceive GIF motion from a single image, so `ImageManager` samples up to 8 evenly-spaced frames (first + last included; `sampleIndices`), re-encodes each to PNG, and `read_image` returns them as a time-ordered sequence. A single-frame GIF is a still. `ImageResult.frames` is therefore a list (1 for stills, N for animated GIFs).
- **`ImageManager.supportedExtensions` is the single source of truth** for which formats `read_image` opens — `AttachmentManager`'s `readable` flag reads it, so the two never drift. Widen formats there, not in two places. SVG is excluded (XXE).
- **Image platform code sits behind `ImageEncoding`.** `ImageManager` is pure policy (caps, pass-through decision, GIF sampling) and is unit-tested with a fake encoder; the macOS ImageIO work is `CoreGraphicsImageEncoder` (`#if canImport(ImageIO)`). A non-macOS port adds another conformer — don't put `ImageIO`/`AppKit` calls in `ImageManager`.
