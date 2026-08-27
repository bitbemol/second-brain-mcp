# Security

SecondBrainMCP runs **locally** as a subprocess of an MCP client (e.g. Claude Desktop or Claude
Code), communicating only over stdin/stdout (`StdioMessageTransport`). It has format-aware read/write
access under `notes/` and structurally read-only access under `references/`. Because it touches
personal files, security is treated as a design constraint, not a feature.

This document covers how to report a vulnerability, the server's security posture, and how to
independently verify its network behavior and dependencies.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for anything exploitable.

- Use GitHub's **[Report a vulnerability](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**
  flow (repository → *Security* tab → *Report a vulnerability*) to open a private advisory.

Please include reproduction steps and the affected commit. You'll get an acknowledgement, and a
fix or mitigation will be coordinated before any public disclosure.

## Threat model

- **Trusted:** the local user, and the MCP client the server is launched by.
- **Not trusted:** the *arguments* of individual tool calls. Paths and content are treated
  as hostile input and validated/rejected. A caller cannot write outside the vault, run arbitrary
  commands, or permanently destroy data. External reads are limited to an explicitly supplied,
  content-gated image/video source for media creation.
- **Out of scope:** what the MCP client does with vault data after the server returns it (that is
  governed by the client and the AI provider's own terms), and physical/OS-level access to the machine.

## Security posture

| Guarantee | How it's enforced |
|-----------|-------------------|
| **No vault path escapes the vault** | Every caller-controlled vault path goes through `PathValidator`: rejects absolute paths, screens for `..` (incl. percent-encoded / Unicode dots), resolves symlinks, and asserts containment within the canonical vault root. Writable targets reject every symlink component. CRUD persistence walks and retains no-follow directory descriptors, binds replacements to the validated source identity, and uses descriptor-relative atomic rename; create and trash destinations are no-clobber. The declared concrete format must also match the extension. |
| **References are read-only by construction** | `WritableFileTarget` can only be resolved under `notes/`, and catalog mutation bindings permit only the notes area. There is no writable representation of a `references/` target. |
| **External sources are content-gated** | Opaque text/structured formats require inline content and cannot read arbitrary source paths. Only PNG image import and video-to-GIF conversion accept an external source; `ExternalFileSourceValidator` requires the canonical target to be a size-capped regular file outside the vault, then copies it through an opened descriptor into a bounded private snapshot before media decoding. Sources are never mutated. Expected source/media policy failures return fixed corrective guidance and numeric limits, never supplied paths or framework details; unknown failures remain opaque. |
| **MCP-prepared credentials are rejected before persistence** | Every textual create/update prepared through the MCP boundary is scanned for strong bearer, authorization, cookie, token-assignment, private-key, JWT, and provider-token signals. Path moves validate the selected file or every existing directory descendant before rename. Rejections report only the detector and line, never the matched value. HAR imports additionally replace known authorization/cookie headers, cookies, URL user information, authentication parameters, and credential fields in JSON/form request bodies with `[REDACTED]`; HAR reads return only the complete sanitized JSON document. Explicit placeholders remain permitted. Direct filesystem edits are outside the MCP ingress policy and may be included by the next notes snapshot, so do not place credentials directly under `notes/`. Detection is defense in depth, not a guarantee that every possible secret format can be recognized, and it does not remove credentials already present in earlier Git history. Rotate and purge any previously committed secret separately. |
| **No caller-selected command execution** | `GitRepository` is the only subprocess boundary. It launches hardcoded `/usr/bin/git` directly—never a shell—with programmatically built arguments, `-C` for the fixed vault URL, and `--` before the fixed `notes` pathspec. Inherited `GIT_*` variables are removed so callers cannot redirect the repository, worktree, index, or configuration. Prompts and paging are disabled; commit hooks are disabled with `core.hooksPath=/dev/null`, signing is disabled, and the local author identity and constant snapshot subject are supplied by the application. Standard output is discarded and standard error is bounded to 32 KiB. Trusted repository configuration, including clean filters invoked by `git add`, remains part of the local Git trust boundary. |
| **No hard deletes of user content** | `delete_file` moves files to a collision-proof recoverable name under a real, non-symlink `.trash/` directory; it preserves parent directories and unrelated files. Permanent cleanup applies only to owned staging/derived artifacts, never user content. Successful deletion exposes the trash locator and deleted-byte revision but grants no new `.trash/` read/write authority. Trash is retained indefinitely with no automatic purge; documented recovery is a local-user copy to an unused `notes/` path while clients are stopped, followed by writable startup recovery. Trash is not an independent backup. |
| **Stale cooperating note edits are rejected** | Reads under `notes/` return a SHA-256 identity of the bytes observed during the protected read. Updates, deletes, and file-form `move_path` require that opaque revision and compare it again under the global exclusive mutation lease; conflicts never disclose a replacement token that could enable blind retry. Applications outside this MCP protocol do not honor its lock, so their writes are rechecked but cannot participate in an atomic cross-application compare-and-swap. |
| **Path moves are atomic, contained, revision-safe, and no-clobber** | `move_path` accepts either one registered file or one proper non-hidden, non-package subtree under `notes/`. It rejects symbolic-link components, self-subtree destinations, case- or Unicode-equivalent source/destination paths, and mismatched file extensions. File moves require the exact source revision and preserve the exact descriptor-validated bytes. Directory moves hash every regular file through one stable descriptor under aggregate count/byte ceilings. Both variants apply persisted-file policy, including structured HAR credential checks and strict encoding for obvious text/configuration paths, then use `renameatx_np(..., RENAME_EXCL)` so an existing destination is never overwritten. The global mutation lease remains held through the rename and required notes snapshot. |
| **Concurrent MCP clients share one vault access boundary** | One writer-preferring `VaultAccessCoordinator` per runtime grants shared read leases and one global exclusive mutation lease. Existing reads finish before a mutation starts; once a mutation waits, later reads wait behind it. The mutation lease covers the entire validation, preparation, filesystem, and Git chain. Independent MCP processes use shared/exclusive modes on the same advisory lock file; OS record-lock polling does not guarantee strict FIFO order between processes. Lock-file naming is a same-version cooperating-host protocol, so an upgrade requires fully stopping and restarting every MCP host for the vault. Direct PDF content/metadata and search extraction share a bounded local queue and vault-scoped cross-process permit. Direct reads acquire it before the vault lease and snapshot; search releases its vault capture lease before acquiring it and loading a private snapshot. Queued PDF callers retain no snapshot bytes, and extraction never reacquires the vault lease. |
| **Search locates content without becoming a read bypass** | `search_vault` selects exactly one structural area and enumerates only globally registered readable textual formats plus registered atom providers such as PDF and Canvas. Hidden entries, nested package directories, symbolic links, non-regular files, unsupported extensions, and paths that fail the contained `ReadableFileTarget` boundary are not searched. Listing and link discovery apply the same package exclusion; direct readable-file authority is unchanged. Scoped source bytes are streamed through stable no-follow descriptors into private immutable captures under the global shared read lease. Extraction and ranking use those captures after releasing the vault lease; per-format size policy still applies. Capture admission, source bytes, file counts and private manifest size are bounded; cleanup runs before releasing the capture lease, including on cancellation. Results contain only format and vault-relative path plus an optional physical PDF page or Canvas node/field locator—never snippets, matched content, derived diagnostics, or mutation revisions. Caller queries are literal data, never regexes, SQL, or subprocess arguments. PDF extraction uses revision-keyed derived page text, bounded admission, cancellation checks, and no rendered-image cache. A request fails safely above 10,000 eligible files, 100,000 scanned entries, 256 MiB of attempted source bytes, or 100,000 atoms. Coverage certifies examination of the search representation, not format-specific validity: JSON, CSV, HAR, patch and log discovery searches raw UTF-8; strict content reads still enforce their format policy. Isolated audited file failures produce incomplete coverage without partial matches; search retains exact bounded per-format failure counts within the existing coverage budget; traversal, path-policy, work-limit and unclassified internal failures abort the request. Traversal path strings and candidate/capture manifests have separate 8 MiB budgets. Complete encoded search locators are capped at 4 KiB and structured search payloads at 256 KiB; over-budget locators make the whole source an explicit incomplete-coverage failure, never a clipped identifier. Result counts and cursor inputs are capped; cursors bind the normalized request, corpus fingerprint, and a real ranked result anchor, so stale or forged continuations are rejected. |
| **Discovery, links, and metadata minimize disclosure** | `list_files` returns only validated canonical paths, registered formats, byte counts, and modified times; it never reads bodies. `query_links` parses bounded local wiki and inline Markdown links, groups backlinks by source by default, and returns only targets and path candidates with request/corpus-bound cursors and explicit coverage, never snippets. `read_file(view: metadata)` returns bounded Markdown or PDF facts without document bodies, PDF page text, or images. It names incomplete fields; exact identifiers are whole or omitted rather than clipped. Every returned path remains untrusted input to a subsequent validated call. |
| **Lost mutation responses require observation** | Mutations do not accept an idempotency key and are not replayed automatically. A normal call returns only after persistence and any required snapshot finish. If the transport loses that response, the caller must use `read_file` or another validated observation before deciding whether to issue a new mutation. A process or machine failure can still occur between vault persistence and Git durability because those filesystem states are not one journaled transaction. |
| **Git records recoverable notes snapshots, not agent ownership** | `VaultMutationExecutor` orders persistence → `VaultVersioning.recordSnapshot()`, finishes that chain after persistence starts even if the caller is canceled, and propagates snapshot failures instead of swallowing them. `GitRepository` stages and commits only `notes/`; `references/` and unrelated staged paths remain outside the snapshot. A snapshot may coalesce pending changes from several agents, and a later snapshot request succeeds as a no-op when its state was already captured. |
| **Optional read-only mode** | `--read-only` exposes only `list_files`, `search_vault`, `query_links`, and `read_file`; it hides every mutation tool, removes mutating operations from capability discovery, rejects direct calls at both frontend and backend boundaries, and skips Git initialization. |

## Network activity

The server contains no network client and requests no outbound network operation in normal use.

- **Transport:** the app-owned `StdioMessageTransport` reads stdin and writes stdout. It serializes
  complete response frames, reads only on demand, and waits for descriptor readiness instead of timer
  polling. Disconnect waits for readiness registrations to stop before borrowed descriptors can be
  closed by their owner. It rejects incomplete EOF frames and caps each incoming
  frame at 192 MiB (including JSON escaping). At most 32 response senders may wait behind an active
  frame; overflow or a partially written failed frame terminates the connection. These are transport
  bounds, not a whole-process memory limit or a cap on decoded SDK request tasks. The server never
  instantiates a network transport. When input ends, the application closes tool admission,
  cancels accepted tool tasks, and joins their unwind before returning from server setup.
  Already-started persistence and its required Git snapshot remain joined; this is not a
  timeout that abandons native work or a guarantee against forced process termination.
- **The MCP SDK ships HTTP/SSE transports** (pulled in via `swift-nio` and `eventsource`); that code
  is compiled into the binary but is **never instantiated or invoked** by SecondBrainMCP.
- **Git** is asked to run only local `init`, `add`, `diff`, `ls-files`, and `commit` operations
  against the vault. The server never requests `push`, `fetch`, or `remote`. Commit hooks and signing
  are disabled. Trusted repository configuration, including clean filters used while staging notes,
  may still execute local programs and remains outside this network claim.
- **PDFKit and Vision** are invoked for local PDF extraction/rendering and OCR; this integration does not request a network operation. A server-process socket check does not independently audit activity inside separate macOS services. PDF search reads immutable captures and stores only revision-keyed, integrity-checked page text under the private application-support directory; cache failures fall back to bounded extraction and publication is best-effort; direct PDF reads use stable byte snapshots rather than allowing PDFKit to reopen caller-controlled paths. Search OCR directly awaits Vision recognition in the caller's task and keeps admission until that public async call returns or throws. It explicitly selects a CPU for recognition stages that advertise CPU support, preserving accurate recognition, language correction and the zero text-height cutoff; unsupported stages retain framework device selection. This small policy passed the recorded repeated-cancellation checks without adding a subprocess. PDFKit document access remains sequential; only a retained immutable page raster and the recognition request cross the native await. Task cancellation does not abandon the call or release admission early, and no universal native cancellation-time guarantee is claimed. Joining public calls does not certify that every private framework thread has quiesced.

You don't have to take that on faith — see [Verifying](#verifying-it-yourself) below.

## Dependencies

The MCP SDK runtime is checked into `Vendor/swift-sdk` at upstream revision
`a0ae212ebf6eab5f754c3129608bc5557637e605` (0.12.1), with a narrowly scoped
JSON-string fidelity patch. Its [provenance record](Vendor/swift-sdk/README.md)
documents local changes and hashes; the complete upstream license is retained.
JSON strings remain strings even when they look like data URIs; explicit binary
encoding is unchanged. No generated dependency checkout is patched.

Swift Subprocess and all remote transitive packages remain version-pinned in the
committed `Package.resolved`. Verification uses `--force-resolved-versions` to
reject resolution drift. The table reflects the local SDK and remote lockfile;
inspect the effective graph with `swift package --force-resolved-versions show-dependencies`.

| Package | Owner | Version | Role |
|---------|-------|---------|------|
| `modelcontextprotocol/swift-sdk` | MCP org | 0.12.1 + local patch | **Direct, vendored** — MCP protocol library; see provenance above |
| `swiftlang/swift-subprocess` | Swift project | 1.0.0 | **Direct** — bounded invocation of the fixed `/usr/bin/git` boundary |
| `apple/swift-log` | Apple | 1.15.0 | Logging to stderr |
| `apple/swift-system` | Apple | 1.8.0 | Low-level system calls |
| `apple/swift-nio` | Apple | 2.101.3 | Async I/O (used by the SDK's HTTP transport — not by this server) |
| `apple/swift-collections` | Apple | 1.6.0 | Data structures |
| `apple/swift-atomics` | Apple | 1.3.1 | Thread-safe primitives |
| `mattt/eventsource` | Mattt Thompson | 1.4.1 | SSE parser pulled in by the SDK — unused by this server |

## Data flow

```
Vault + an explicitly supplied image/video source (local disk)
  → SecondBrainMCP (local process, stdin/stdout only)
    → MCP client (e.g. Claude Desktop / Claude Code)
      → AI provider API (HTTPS, performed by the client — not by this server)
```

The only point where vault data leaves the machine is the **client → provider** hop, which is
governed by that client and provider's data-handling terms — not by this server.

## Verifying it yourself

**Inspect the running server's network sockets** (two terminals):

```bash
# Terminal 1 — use a disposable vault and leave stdin attached to this terminal
.build/release/second-brain-mcp --vault /absolute/path/to/disposable-vault --read-only

# Terminal 2 — replace SERVER_PID with this exact process's PID from Activity Monitor
lsof -nP -i -a -p SERVER_PID
```

Empty output means no matching network socket was observed for that process at
that instant; it does not prove the absence of transient sockets or activity in
separate OS services. Stop only the server you started with Control-C in terminal 1.
Do not select or terminate an arbitrary process by name: another MCP client may
have a server running against a real vault.

**Audit the dependency graph and scan the SDK source for phone-home code:**

```bash
swift package show-dependencies
rg -ni 'telemetry|analytics|tracking|beacon|phone.home' Vendor/swift-sdk/Sources .build/checkouts/
```

## Dependency update policy

Updates are deliberate, never automatic — a new transitive dependency could introduce network calls
or telemetry, so each update is audited before it lands.

1. Branch — never update on `main`.
2. `swift package update`, then review `git diff Package.resolved` and `swift package show-dependencies`.
3. Re-run the telemetry grep and the `lsof` network check above.
4. `swift test`.
5. Merge only after all checks pass.
