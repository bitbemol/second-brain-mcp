# SecondBrainMCP

A local MCP server in Swift that gives MCP clients format-aware access to a knowledge vault.
Files under `notes/` are writable, `references/` is structurally read-only, and every successful
changed-byte mutation requests a recoverable snapshot of the notes tree. File CRUD is exposed through four generic tools
with an explicit concrete `format` argument; `search_vault` is a separate bounded read-only port.

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
- PDF: `PDFKit` + `Vision` (system frameworks, zero deps) — page rendering, text extraction, and OCR
- Built-in subprocess boundary: `/usr/bin/git` only (see Rule 4)

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
│       ├── Directories/               # Structural subtree-move adapter
│       ├── Files/                     # Generic CRUD schemas and adapters
│       └── Search/                    # Locator-only search schema, decoder, and mapper
├── Backend/                          # Internal application behavior
│   ├── Concurrency/                  # Injected global vault access coordinator
│   ├── Directories/                  # Atomic subtree move implementation
│   ├── Files/
│   │   ├── Ingress/                  # Request-to-bytes policy for stored text
│   │   ├── Operations/               # Format validation/transformation/read behavior
│   │   ├── Routing/                  # Bindings, catalog, operation families, service
│   │   ├── Storage/                  # Generic snapshots, persistence, and soft deletion
│   │   ├── Targets/                  # Validated readable/writable paths
│   │   ├── Transactions/             # Prepared persistence and awaited Git sequencing
│   │   └── Validation/               # Vault and external-source security
│   ├── Media/                        # Image and video processing
│   ├── Search/                       # Atom providers, matching, and cursor pagination
│   ├── VaultVersioning/              # Sole Git subprocess boundary
│   └── …                             # Canvas, references, and infrastructure
└── Shared/                           # Cross-boundary contracts and utilities
    ├── Files/                        # File and directory operation contracts, formats, output
    ├── Search/                       # Search request/result/service contracts
    └── Logging/                      # Process-level stderr logger
```

Keep the executable target and product identity aligned as `second-brain-mcp`; Swift exposes that
target to source as module `second_brain_mcp`, which is what the test target imports. Do not map a
differently named executable product onto target `SecondBrainMCP`: command-line SwiftPM accepts
that graph, but Xcode 26 builds the product module as `second_brain_mcp` and then cannot resolve the
testable `SecondBrainMCP` module.

Search stays outside CRUD:

```
search_vault
  → SearchToolController decodes a Shared VaultSearchRequest
  → VaultSearchEngine validates criteria and cursor state
  → SearchCorpusBuilder enumerates exactly one VaultArea through FileCapabilities
  → a SearchAtomProvider represents each file as whole-file or page atoms
  → a SearchMatchingStrategy ranks matches
  → the frontend returns locators only
```

The Shared boundary is intentionally small: `VaultSearchService`, `VaultSearchRequest`, and the locator-only response. Search never returns snippets or content; callers pass the returned global `FileFormat`, path, and optional PDF page to `read_file`.

Readable textual formats automatically use the whole-file atom provider, so adding a globally registered textual format requires no search-specific enum or capability type. Markdown remains one note atom and reuses the shared frontmatter parser for tags and created dates. PDFs register the only custom production provider: one atom per physical page, with revision-keyed extracted text under the private application-support directory and Vision OCR when embedded text is absent. Once a candidate path passes validation, a file-local snapshot or atom-provider failure omits only that file; cancellation and path-validation failures still abort the complete request.

Matching and representation are separate protocols, but the public tool exposes no strategy switch. The default literal strategy requires every normalized query term in the same atom, then uses phrase and occurrence strength only for deterministic order. Duplicate normalized terms preserve their ranking multiplicity but each distinct term is scanned only once; do not reintroduce one full atom scan per raw query token. Cursor pagination is request-bound and keyset-based; the cursor also carries a deterministic fingerprint of the searchable atoms. For an unchanged vault it exposes every match by repeating the same request until `next_cursor` is absent. If the corpus changes, continuation fails as stale and the caller restarts instead of risking a skipped atom. During a scan, retain only the best `limit + 1` ranked matches in bounded storage and sort that retained page; sorting every match makes dense queries scale unnecessarily with the complete result set.


The generic file pipeline is:

```
MCP request
  → FileToolController strictly decodes a Shared CRUD request
  → VaultFileService resolves an explicit FileFormat binding + safe target
  → create: the registered payload contract is enforced before dispatch
  → stored-text ingress validates inline content before its format handler
  → format handler prepares/interprets bytes
      ├─ read: one immutable snapshot supplies both handler bytes and revision
      └─ mutation: VaultMutationExecutor persists → awaits VaultVersioning.recordSnapshot()
```

Stored-text reads and updates can operate on the full 10 MiB file limit. Preserve one strict UTF-8
decode for ordinary non-BOM content, retain the first exact-patch range while proving uniqueness,
and assemble appends in one reserved buffer. Re-decoding, re-searching after uniqueness is known,
or chained whole-string concatenation turns a bounded edit into avoidable duplicate full-file work.

`move_directory` remains outside file CRUD because it changes one tree boundary over a set of
file atoms rather than one atom's bytes. Its frontend controller decodes the Shared
`MoveDirectoryRequest` and calls the Shared `DirectoryMoveService` port; the backend implementation
owns path policy, subtree validation, the atomic rename, and the awaited snapshot request. The tool
has no `format` argument and returns only its source and destination paths.

`FileFormat` is concrete storage format only. Semantic roles such as “attachment” or “reference”
belong to vault area/policy, never in that enum. `FileFormatDefinition` binds each operation
independently, so multiple formats can share a handler and a format can use a special handler for
only one operation.

**Concurrency:** `VaultRuntime` creates one `VaultAccessCoordinator` and injects it through the
`VaultAccessCoordinating` protocol. Shared leases allow reads to overlap. A mutation waits for every
active read, then holds the exclusive lease through validation, preparation, persistence, and Git.
Writer preference prevents later reads from bypassing a queued mutation. In-process waiters use an identified FIFO queue so cancellation removal stays constant-time and dequeue stays amortized constant-time; do not replace it with array scans or front removal. Independent processes use
shared/exclusive modes on the same advisory lock file. `read_file` captures each file once and gives
that immutable snapshot to the routed handler. Immutable snapshot loading is nonisolated from the
mutation store actor so shared reads actually overlap; persistence remains actor-serialized. The
exact-byte revision is thread-safe and lazily memoized, so note mutations and search caches still
identify the captured bytes while direct reference reads avoid hashing content they never version.
Update/delete must compare that opaque revision before changing bytes.

Writable startup composes the runtime, connects the MCP transport, then begins pending-change
recovery. Initialization and tool discovery therefore remain responsive during a slow or contended
Git snapshot. Mutating calls await the same recovery task before entering the backend; reads are
accepted but still obey the shared/exclusive coordinator lease. A recovery failure remains stored in
that gate and is returned to every mutation, but it must not stop an already connected server:
discovery and reads stay available. Recovery success/failure and transport completion are logged to
stderr so a field report can distinguish Git failure from the client closing its transport.

Queued cancellation does no work. Cancellation is checked before prepared persistence begins; after
that point `VaultMutationExecutor` finishes persistence and the required snapshot in a detached task
before the exclusive lease is released. There is no mutation ID or durable response replay. After a
lost response, the caller reads the current target state before deciding whether another mutation is
needed. A snapshot may coalesce pending changes from several agents. Sudden machine or storage power
loss remains outside the transaction guarantee because vault bytes and Git refs are not one jointly
synchronized filesystem transaction.

### Layering & guardrails

Dependencies flow one way: `Frontend → Backend → Shared`. System frameworks are imported only
by the narrowest layer that needs them.

- **MCP types stay in `Frontend/MCP/`.** Backend accepts plain Swift request/target types, returns
  plain Swift output, and throws domain errors. Never `import MCP` in `Backend/` or `Shared/`.
- **The frontend is split by responsibility.** Startup/dispatch stays in
  `Frontend/MCP/MCPServerSetup.swift`; generic file schemas and adapters live in
  `Frontend/MCP/Files/`; search schemas and adapters live in `Frontend/MCP/Search/`; CLI parsing
  lives in `Frontend/Configuration/`.
- **Shared is deliberately small.** Put code there only when both sides consume the same stable
  value or utility. Shared must not contain MCP schemas, filesystem orchestration, managers, or
  feature policy; it is not a miscellaneous helper directory.
- **Format handlers do not load arbitrary input or persist.** Stored-text create requests pass
  through `TextFileIngress`; handlers validate, transform, or interpret the resulting bytes. All
  generic creates, replaces, and soft deletes go through `VaultCRUDStore`.
- **Writable targets are structural.** `WritableFileTarget` has no public initializer and can
  only resolve paths under `notes/`; code cannot construct a writable `references/` target.
- **Internal handler IDs stay internal.** The format catalog projects concrete formats, creation
  inputs, update modes, operations, and areas into the generic CRUD tool schemas—not implementation identities.
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

### 4. No caller-selected command execution

Only `/usr/bin/git` (via `GitRepository`) may be launched directly, with programmatic argument
arrays and `--` guards. Never interpolate user input into a command. Git may honor hooks, signing,
filters, or other extension points installed by the trusted local user; do not describe this as a
general process sandbox.

### 5. Soft deletes only

`delete_file` moves user content to a collision-proof path under `.trash/`. Never permanently
remove user content. Removing a temporary file created by the store itself is allowed cleanup.

### 6. Mutation → versioning is one awaited transaction responsibility

`VaultFileService` validates and prepares under the exclusive `VaultAccessCoordinating` lease.
`VaultMutationExecutor` owns prepared persistence followed by any required versioning request.
`VaultVersioning` is the only version-control interface, and `GitRepository` owns all Git state.
Do not persist or invoke Git in a format handler or MCP adapter. The caller's mutation lease must
remain held through the complete persistence-and-snapshot chain. Snapshot failures are propagated
explicitly—even if the filesystem mutation already succeeded—rather than swallowed with `try?`.

## Conventions & design intent

- **Validate at ingress; own everything inside; never mutate what's outside.** External `source`
  files are canonicalized, regular-file-only, size-capped, and read-only. The server never moves,
  deletes, or edits them.
- **Require the concrete format.** Do not infer it solely from an extension or payload. The
  explicit enum makes support discoverable before a client sends data; extension/content checks
  then defend against mismatches.
- **Reject, don't silently repair.** Bad paths, wrong formats, malformed JSON/CSV/HAR/Canvas/diffs, and
  unsupported operations are errors.
- **Secrets stop before Git.** Every prepared textual create/update passes the shared high-confidence
  credential policy before persistence. It reports only detector + line, never the matched value.
  HAR is the deliberate transformation exception: known authorization/cookie/token fields are
  replaced with `[REDACTED]`, the result reports the redaction count, and reads return the complete sanitized JSON atom.
- **Prepare, then persist.** A special create/update handler returns bytes; it never writes them.
  Generic persistence and git behavior remain identical across formats.
- **Reuse functions, not manager-shaped dependency bags.** If several formats share behavior,
  bind them to the same operation function. Add a special function only for the operation that
  needs it.
- **No swallowed errors in security/mutation paths.**
- **Use actors for mutable state and Sendable values for wiring.** A narrow synchronized resource
  wrapper may use `@unchecked Sendable` only when its invariants and locking are documented, as with
  the idempotently closed advisory-lock lease.
- **Keep files focused.** One cohesive type or family per file; split before a file becomes a
  mixed-responsibility boundary.
- **Tests use temporary vaults** and never touch user content.
- **Repo commits use Conventional Commits**; vault recovery commits use the stable `Vault snapshot` subject.

## Adding a file format

1. Add the concrete case and extension aliases to
   `Shared/Files/FileFormat.swift`.
2. Add its supported file-size tier to
   `Backend/Files/Validation/FileResourcePolicy.swift`.
3. Reuse the generic stored-text read/update/delete behavior when possible. Add a focused handler in
   `Backend/Files/Operations/` only for create-time validation/transformation or a genuinely special
   read such as logs, images, or PDFs. Handlers prepare values; they do not persist.
4. Handle the new case in the exhaustive `FileFormat` switch in
   `Backend/Files/Routing/FileFormatCatalogFactory.swift`. Declare its create input contract,
   validator or special read, supported update modes, and allowed vault areas. Never add a
   `default`; the compiler must require every format to be wired.
5. Extend the exact capability-matrix expectation in `VaultFileServiceTests`.
6. Add focused handler tests plus a routed service test when mutation policy changes.
7. Run `swift test` and the DocC warnings-as-errors check.

Do not edit four MCP schemas when adding a format. Tool format enums, create
input requirements, and update modes derive from the catalog automatically.
Any readable textual format is searchable as one whole-file atom. Register a focused
`SearchAtomProvider` only when a format needs a different atomic representation.

## Where data lives

**User content lives in the vault:** `notes/` (git-tracked), `references/` (gitignored), optional
`INSTRUCTIONS.md` (appended to the server's instructions), plus `.trash/` and `.git/`.

**MCP-internal data lives OUTSIDE the vault** at
`~/Library/Application Support/SecondBrainMCP/<sha256-of-vault-path>/` — see
`VaultDataDirectory`. This keeps process-owned locks and derived search data out of user content and Git.

Server logs (stderr) are captured by Claude Desktop at
`~/Library/Logs/Claude/mcp-server-second-brain.log`.

## PDF subsystem

- `read_file(format: pdf)` retrieves physical pages; it never searches or returns document
  navigation metadata. Every selected page produces exactly one bounded text block and one PNG image.
- Select one page with `page`, an ordered unique set with `pages`, or an inclusive range with
  `page_range`. Selectors are mutually exclusive, default to page 1, and may return at most 20 pages.
- A requested set is all-or-error: invalid, missing, unrenderable, or aggregate-oversized pages are
  rejected rather than silently omitted. Content queries belong exclusively to `search_vault`.
- `search_vault(location: references)` represents each PDF page as an atom. It caches page text
  by exact file revision under `VaultDataDirectory.searchIndexDirectoryURL`, prefers embedded
  PDFKit text, and uses Vision OCR only when a page has no embedded text.
- PDF search extraction and direct reads share `PDFReadAdmission`; page work uses autorelease
  scopes and cooperative cancellation. Direct reads render the immutable service snapshot and use
  bounded raster dimensions; cached OCR text remains derived search data, never mutation authority.


## Gotchas

- **SIGPIPE must stay ignored** (`signal(SIGPIPE, SIG_IGN)` in `main.swift`) — Claude Desktop closing
  the pipe would otherwise silently kill the process.
- **PDFKit pages are 0-indexed**; users and tools are 1-indexed — convert at the boundary.
- **PDF reads under `references/` are `.pdf`-specific.** Generic image reads may also target
  supported image files under `references/`; writes still cannot.
- **Canvas writes are lossless on purpose.** `CanvasModel.validate` only *decodes to prove* the JSON is well-formed JSON Canvas (unique node ids, edges reference existing nodes, valid enum/color values) — it is **never re-serialized**. `create_file`/`update_file` with `format: canvas` write the caller's **original bytes**, so plugin-added keys outside the 1.0 spec survive. Don't "round-trip through the model" — that would drop those keys.
- **General JSON and CSV writes are lossless too.** Their handlers parse only to prove validity and persist the caller's UTF-8 representation unchanged. JSON accepts any valid top-level value and supports replace/exact-patch updates; append is rejected because concatenated JSON values are not one document. CSV supports replace/append/exact-patch updates and validates quoted fields, escaped quotes, embedded line breaks, and consistent column counts after every change.
- **Complete text reads can dwarf model context.** Markdown, Canvas, patch, JSON, and CSV may return up to 10 MiB atomically, and HAR up to 25 MiB. Server I/O can be fast while the MCP client or model appears stalled on millions of tokens. Fix this with an explicit chunked/paginated text-read contract; do not silently truncate or invent a smaller storage limit.
- **Canvas validates structure, not external links.** `CanvasModel.validate` rejects dangling **edge→node** references (intra-document structural integrity), but a **file-node→file** reference is an extra-document soft link the spec and Obsidian tolerate, so it is not existence-checked. Reads return the complete validated Canvas JSON atom without a synthesized summary.
- **`read_file(format: <image>)` transforms only when it must.** A still within the model's native resolution (long edge ≤ 2576px) whose format the API accepts natively (png/jpeg/gif/webp) is passed through **byte-for-byte** with its own mime type — re-encoding does nothing for readability, the only reason to transform is size. Oversized stills, and formats the API won't accept (heic/tiff/bmp), are re-encoded to PNG. The **decode-bomb guard is `ImageEncoding.inspect`**: it reads dimensions + frame count *without* decoding, and `ImageReader` rejects >50 MP before any read decode. `ImageImporter` applies the same guard before import decoding. Keep that order — inspect, reject, only then decode.
- **Animated GIFs return a frame *bundle*, not one image.** The model can't perceive GIF motion from a single image, so `ImageReader` samples up to 8 evenly-spaced frames (first + last included; `sampleIndices`), re-encodes each to PNG, and `read_file(format: <image>)` returns them as a time-ordered sequence. A single-frame GIF is a still. `ImageReader.ImageResult.frames` is therefore a list (1 for stills, N for animated GIFs). **Each frame also carries its wall-clock offset** (`Frame.timeOffsetSeconds`), with the total in `ImageResult.totalDurationSeconds` — both nil for stills or a GIF with no delay metadata. The delays come from `ImageInspection.frameDelays` (read in `inspect`, **metadata only — no pixel decode**, so the bomb guard is untouched); `ImageReader.cumulativeTime` does the summing. Encoded frame bytes are accumulated with overflow checks and rejected once the image-format file limit is exceeded; base64 still expands an accepted maximum bundle by roughly one third on the wire.
- **`FileFormat.imageExtensions` is the single source of truth** for which image extensions
  the vault reader accepts. SVG is excluded (XXE).
- **`create_file` is the only tool that accepts an external source path.** `ExternalFileSourceValidator` canonicalizes every source, requires a regular file, size-caps the resolved target, and refuses paths that resolve inside the vault. It then copies the opened descriptor into a bounded private snapshot so a concurrent source replacement cannot change what media frameworks decode. For `format: png`, image decode is an additional gate and the output is re-encoded to a clean, long-edge-capped PNG, so EXIF, trailing bytes, and polyglot payloads do not enter the vault. The destination is still `PathValidator`-gated under `notes/`, reject-if-exists, and must already use `.png`. Sources are only read—never moved, deleted, or modified.
- **Image platform code sits behind `ImageEncoding`.** `ImageReader` and `ImageImporter` own policy
  and are unit-tested with fake encoders; macOS ImageIO work lives in
  `CoreGraphicsImageEncoder` (`#if canImport(ImageIO)`). A non-macOS port adds another conformer—do
  not put `ImageIO`/`AppKit` calls in the policy types.
- **`create_file(format: gif, transform: video_to_gif)` converts in-process with AVFoundation + ImageIO—never ffmpeg / `Process()`.** It samples an external source video into an animated GIF under `notes/`; `read_file(format: gif)` then exposes timed PNG frames. `ExternalFileSourceValidator` owns filesystem trust checks, `VideoImporter` owns conversion policy and serializes conversions with `AsyncExclusiveGate`, and `VideoEncoding` owns platform work. Caps are 10 fps, 1080px long edge, 120 frames, 512 MB source, 30 minutes, and the GIF format's 25 MB file limit. Encoded GIF bytes are written to a private temporary file and read back through the output byte ceiling.
