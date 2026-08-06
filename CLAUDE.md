# SecondBrainMCP

A local MCP server in Swift that gives MCP clients format-aware access to a knowledge vault.
Files under `notes/` are writable, `references/` is structurally read-only, and every mutation
is auto-committed to git. File CRUD is exposed through four generic tools with an explicit
concrete `format` argument.

The codebase favors **clear boundaries and structural safety over cleverness**: security is
enforced by architecture (not runtime flags), there are zero third-party dependencies beyond the
MCP SDK, and every rule below is load-bearing and covered by tests. **New here?** Read
[Critical Rules](#critical-rules--do-not-violate) and
[Layering & guardrails](#layering--guardrails) first — they're the
walls everything else leans on.

This file is for working *in* the code. `README.md` is the user-facing doc (setup, full tool and
resource reference).

## Stack

- Swift 6.2 (strict concurrency), macOS 26 (Tahoe), Xcode 26
- MCP SDK: `modelcontextprotocol/swift-sdk`, pinned `from: "0.12.0"` (see `Package.swift`)
- Transport: `StdioTransport` (stdin/stdout JSON-RPC)
- PDF: `PDFKit` (system framework, zero deps) — page→JPEG rendering + text extraction
- Subprocesses: `/usr/bin/git` only (see Rule 4)

## Commands

```bash
swift build                            # Debug build
swift build -c release                 # Release → .build/release/second-brain-mcp
swift test                             # Full suite — keep it green
swift test --filter PathValidatorTests # The security suite — this one must never fail
```

Run by hand: `second-brain-mcp --vault <path> [--read-only]`

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
├── Frontend/                         # Public CLI and MCP boundary
│   ├── Application/main.swift
│   ├── Configuration/                # CLI argument parsing
│   └── MCP/
│       ├── MCPServerSetup.swift       # Transport lifecycle and handler registration
│       └── Files/                     # Generic CRUD adapters + capability resource
├── Backend/                          # Internal application behavior
│   ├── Files/
│   │   ├── Ingress/                  # Request-to-bytes policy for stored text
│   │   ├── Operations/               # Format validation/transformation/read behavior
│   │   ├── Routing/                  # Bindings, catalog, operation families, service
│   │   ├── Storage/                  # Generic snapshots, persistence, and soft deletion
│   │   ├── Targets/                  # Validated readable/writable paths
│   │   ├── Transactions/             # Mutation, Git, and audit sequencing
│   │   └── Validation/               # Vault and external-source security
│   ├── Media/                        # Image and video processing
│   └── …                             # Canvas, references, Git, logging, infrastructure
└── Shared/                           # Cross-boundary contracts and utilities
    ├── Files/                        # Concrete formats, CRUD contracts, capabilities, output
    └── Logging/                      # Process-level stderr logger
```

The generic file pipeline is:

```
MCP request
  → FileToolController decodes a Shared CRUD request
  → VaultFileService resolves an explicit FileFormat binding + safe target
  → stored-text ingress validates inline content before its format handler
  → format handler prepares/interprets bytes
      ├─ read: VaultFileService returns output and records the audit event
      └─ mutation: VaultMutationExecutor runs VaultCRUDStore → GitRepository → AuditLogger
```

`FileFormat` is concrete storage format only. Semantic roles such as “attachment” or “reference”
belong to vault area/policy, never in that enum. `FileFormatDefinition` binds each operation
independently, so multiple formats can share a handler and a format can use a special handler for
only one operation.

**Concurrency:** mutable state and filesystem sequencing use actors. Routing definitions and
stateless handlers are `Sendable`. `AsyncExclusiveGate` keeps each generic mutation and its git
commit together across actor suspension; snapshot comparison rejects stale updates.

### Layering & guardrails

Dependencies flow one way: `Frontend → Backend → Shared`. System frameworks are imported only
by the narrowest layer that needs them.

- **MCP types stay in `Frontend/MCP/`.** Backend accepts plain Swift request/target types, returns
  plain Swift output, and throws domain errors. Never `import MCP` in `Backend/` or `Shared/`.
- **The frontend is split by responsibility.** Startup/dispatch stays in
  `Frontend/MCP/MCPServerSetup.swift`; generic file schemas and adapters live in
  `Frontend/MCP/Files/`; CLI parsing lives in `Frontend/Configuration/`.
- **Shared is deliberately small.** Put code there only when both sides consume the same stable
  value or utility. Shared must not contain MCP schemas, filesystem orchestration, managers, or
  feature policy; it is not a miscellaneous helper directory.
- **Format handlers do not load arbitrary input or persist.** Stored-text create requests pass
  through `TextFileIngress`; handlers validate, transform, or interpret the resulting bytes. All
  generic creates, replaces, and soft deletes go through `VaultCRUDStore`.
- **Writable targets are structural.** `WritableFileTarget` has no public initializer and can
  only resolve paths under `notes/`; code cannot construct a writable `references/` target.
- **Internal handler IDs stay internal.** The capability resource exposes concrete formats,
  extensions, operations, and areas—not implementation identities.
- **No second `Process()` site.** `GitRepository` is the only subprocess boundary;
  image/video/PDF work stays in-process.

## Critical Rules — do not violate

### 1. Never write to stdout

Stdout is the JSON-RPC transport. Log to stderr only.

### 2. Path security is non-negotiable

All caller-controlled vault paths must pass `PathValidator.resolve(...)`. It rejects absolute
paths, traversal (including encoded/Unicode forms), symlink escapes, and prefix-confusion attacks.
The generic API additionally resolves a `ReadableFileTarget` or `WritableFileTarget` and requires
the declared format to match the path extension.

### 3. Write boundaries are structural, not flag-based

| Area | Read | Write | Move | Delete |
|------|------|-------|------|--------|
| `notes/` | supported formats | ✓ | notes only | soft only |
| `references/` | supported formats | ✗ | ✗ | ✗ |
| internal data | internal | internal | ✗ | ✗ |

`WritableFileTarget` has no representation for `references/`, and catalog mutation bindings must
remain restricted to `notes/`.

### 4. No arbitrary shell execution

Only `/usr/bin/git` (via `GitRepository`) may run, with programmatic argument arrays and `--`
guards. Never interpolate user input into a command.

### 5. Soft deletes only

`delete_file` moves user content to a collision-proof path under `.trash/`. Never permanently
remove user content. Removing a temporary file created by the store itself is allowed cleanup.

### 6. Mutation → Git → audit is one transaction responsibility

`VaultFileService` validates, prepares, and submits a `VaultMutationPlan`.
`VaultMutationExecutor` owns serialized persistence, Git commit, and audit sequencing through
`AsyncExclusiveGate`. Do not persist or commit in a format handler or MCP adapter. Git failures are
propagated explicitly—even if the filesystem mutation already succeeded—rather than swallowed
with `try?`.

## Conventions & design intent

- **Validate at ingress; own everything inside; never mutate what's outside.** External `source`
  files are canonicalized, regular-file-only, size-capped, and read-only. The server never moves,
  deletes, or edits them.
- **Require the concrete format.** Do not infer it solely from an extension or payload. The
  explicit enum makes support discoverable before a client sends data; extension/content checks
  then defend against mismatches.
- **Reject, don't silently repair.** Bad paths, wrong formats, malformed HAR/Canvas/diffs, and
  unsupported operations are errors.
- **Prepare, then persist.** A special create/update handler returns bytes; it never writes them.
  Generic persistence and git behavior remain identical across formats.
- **Reuse functions, not manager-shaped dependency bags.** If several formats share behavior,
  bind them to the same operation function. Add a special function only for the operation that
  needs it.
- **No swallowed errors in security/mutation paths.**
- **Use actors for mutable state, Sendable values for wiring, and no `@unchecked Sendable`.**
- **Keep files focused.** One cohesive type or family per file; split before a file becomes a
  mixed-responsibility boundary.
- **Tests use temporary vaults** and never touch user content.
- **Repo commits use Conventional Commits**; vault commits use `[SecondBrainMCP]`.

## Adding a file format

1. Add the concrete case and extension aliases to
   `Shared/Files/FileFormat.swift`.
2. Add its supported file-size tier to
   `Backend/Files/Validation/FileResourcePolicy.swift`.
3. Reuse an existing operation function or add a focused handler in
   `Backend/Files/Operations/`. Handlers validate/prepare/read; they do not persist.
4. Register a `FileFormatDefinition` in
   `Backend/Files/Routing/FileFormatCatalogFactory.swift`, binding only supported operations and
   allowed vault areas.
5. Extend the exact capability-matrix expectation in `VaultFileServiceTests`.
6. Add focused handler tests plus a routed service test when mutation policy changes.
7. Run `swift test` and the DocC warnings-as-errors check.

Do not edit four MCP schemas when adding a format. Tool format enums and
`secondbrain://file-capabilities` derive from the catalog automatically.

## Where data lives

**User content lives in the vault:** `notes/` (git-tracked), `references/` (gitignored), optional
`INSTRUCTIONS.md` (appended to the server's instructions), plus `.trash/` and `.git/`.

**MCP-internal data lives OUTSIDE the vault** at
`~/Library/Application Support/SecondBrainMCP/<sha256-of-vault-path>/` — see
`VaultDataDirectory`. This avoids iCloud conflicts from process-owned data. Writable startup uses
`LegacyVaultDataMigrator` to preserve an old in-vault audit log and remove known obsolete cache
entries; read-only startup deliberately performs no vault migration.

Server logs (stderr) are captured by Claude Desktop at
`~/Library/Logs/Claude/mcp-server-second-brain.log`.

## PDF subsystem

- `read_file(format: pdf)` returns **dual content per page**: extracted text (`.text`) + a JPEG render
  (`.image`). Text is fast and accurate; the image catches diagrams, equations, and scans. Defaults
  to 5 pages, **hard cap 20**. Render tuning (DPI, JPEG quality, max dimension) lives in
  `PDFPageRenderer.RenderConfig.default`.
- Navigation: `page` (physical, 1-indexed), `book_page` (printed label, e.g. "42"/"xii"),
  `page_range`, or `query` (bounded page-by-page search within that one PDF). Bookmark entries and
  traversal are both capped; printed-label lookup also scans and releases one page at a time.
- Cancellation propagates through `FileToolExecutor`; it does not advertise an in-process deadline
  that structured concurrency cannot enforce around blocking PDFKit work. A hard deadline would
  require isolating native framework work in a separate worker process.
- PDF query search runs against the already-open `PDFDocument`, releases each page through an
  autorelease pool, and stops as soon as the requested result count is reached. There is no
  background index or cache to synchronize.

## Gotchas

- **SIGPIPE must stay ignored** (`signal(SIGPIPE, SIG_IGN)` in `main.swift`) — Claude Desktop closing
  the pipe would otherwise silently kill the process.
- **PDFKit pages are 0-indexed**; users and tools are 1-indexed — convert at the boundary.
- **PDF reads under `references/` are `.pdf`-specific.** Generic image reads may also target
  supported image files under `references/`; writes still cannot.
- **Canvas writes are lossless on purpose.** `CanvasModel.validate` only *decodes to prove* the JSON is well-formed JSON Canvas (unique node ids, edges reference existing nodes, valid enum/color values) — it is **never re-serialized**. `create_file`/`update_file` with `format: canvas` write the caller's **original bytes**, so plugin-added keys outside the 1.0 spec survive. Don't "round-trip through the model" — that would drop those keys.
- **Canvas validates structure, not external links.** `CanvasModel.validate` rejects dangling **edge→node** references (intra-document structural integrity) but a **file-node→file** reference is an extra-document soft link the spec and Obsidian tolerate — so it's *not* existence-checked on write. `CanvasFileOperations.read` surfaces a broken one as a non-blocking `⚠ file not found`. Don't "fix" this asymmetry by rejecting file-nodes on write — it would reject canvases Obsidian accepts.
- **`read_file(format: <image>)` transforms only when it must.** A still within the model's native resolution (long edge ≤ 2576px) whose format the API accepts natively (png/jpeg/gif/webp) is passed through **byte-for-byte** with its own mime type — re-encoding does nothing for readability, the only reason to transform is size. Oversized stills, and formats the API won't accept (heic/tiff/bmp), are re-encoded to PNG. The **decode-bomb guard is `ImageEncoding.inspect`**: it reads dimensions + frame count *without* decoding, and `ImageReader` rejects >50 MP before any read decode. `ImageImporter` applies the same guard before import decoding. Keep that order — inspect, reject, only then decode.
- **Animated GIFs return a frame *bundle*, not one image.** The model can't perceive GIF motion from a single image, so `ImageReader` samples up to 8 evenly-spaced frames (first + last included; `sampleIndices`), re-encodes each to PNG, and `read_file(format: <image>)` returns them as a time-ordered sequence. A single-frame GIF is a still. `ImageReader.ImageResult.frames` is therefore a list (1 for stills, N for animated GIFs). **Each frame also carries its wall-clock offset** (`Frame.timeOffsetSeconds`), with the total in `ImageResult.totalDurationSeconds` — both nil for stills or a GIF with no delay metadata. The delays come from `ImageInspection.frameDelays` (read in `inspect`, **metadata only — no pixel decode**, so the bomb guard is untouched); `ImageReader.cumulativeTime` does the summing.
- **`FileFormat.imageExtensions` is the single source of truth** for which image extensions
  the vault reader accepts. SVG is excluded (XXE).
- **`create_file` is the only tool that accepts an external source path.** `ExternalFileSourceValidator` canonicalizes every source, requires a regular file, size-caps the resolved target, and refuses paths that resolve inside the vault. It then copies the opened descriptor into a bounded private snapshot so a concurrent source replacement cannot change what media frameworks decode. For `format: png`, image decode is an additional gate and the output is re-encoded to a clean, long-edge-capped PNG, so EXIF, trailing bytes, and polyglot payloads do not enter the vault. The destination is still `PathValidator`-gated under `notes/`, reject-if-exists, and must already use `.png`. Sources are only read—never moved, deleted, or modified.
- **Image platform code sits behind `ImageEncoding`.** `ImageReader` and `ImageImporter` own policy
  and are unit-tested with fake encoders; macOS ImageIO work lives in
  `CoreGraphicsImageEncoder` (`#if canImport(ImageIO)`). A non-macOS port adds another conformer—do
  not put `ImageIO`/`AppKit` calls in the policy types.
- **`create_file(format: gif, transform: video_to_gif)` converts in-process with AVFoundation + ImageIO—never ffmpeg / `Process()`.** It samples an external source video into an animated GIF under `notes/`; `read_file(format: gif)` then exposes timed PNG frames. `ExternalFileSourceValidator` owns filesystem trust checks, `VideoImporter` owns conversion policy and serializes conversions with `AsyncExclusiveGate`, and `VideoEncoding` owns platform work. Caps are 10 fps, 1080px long edge, 120 frames, 512 MB source, 30 minutes, and the GIF format's 25 MB file limit. Encoded GIF bytes are written to a private temporary file and read back through the output byte ceiling.
