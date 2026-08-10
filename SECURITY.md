# Security

SecondBrainMCP runs **locally** as a subprocess of an MCP client (e.g. Claude Desktop or Claude
Code), communicating only over stdin/stdout (`StdioTransport`). It has format-aware read/write
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
| **No vault path escapes the vault** | Every caller-controlled vault path goes through `PathValidator`: rejects absolute paths, screens for `..` (incl. percent-encoded / Unicode dots), resolves symlinks, and asserts containment within the canonical vault root. Writable targets reject every symlink component and are revalidated immediately before use. The declared concrete format must also match the extension. |
| **References are read-only by construction** | `WritableFileTarget` can only be resolved under `notes/`, and catalog mutation bindings permit only the notes area. There is no writable representation of a `references/` target. |
| **External sources are content-gated** | Opaque text/structured formats require inline content and cannot read arbitrary source paths. Only PNG image import and video-to-GIF conversion accept an external source; `ExternalFileSourceValidator` requires the canonical target to be a size-capped regular file outside the vault, then copies it through an opened descriptor into a bounded private snapshot before media decoding. Sources are never mutated. |
| **MCP-prepared credentials are rejected before persistence** | Every textual create/update prepared through the MCP boundary is scanned for strong bearer, authorization, cookie, token-assignment, private-key, JWT, and provider-token signals. Directory moves validate every existing descendant before rename, and exact snapshot recovery revalidates the persisted bytes it expects. Rejections report only the detector and line, never the matched value. HAR imports additionally replace known authorization/cookie headers, cookies, URL user information, authentication parameters, and credential fields in JSON/form request bodies with `[REDACTED]`; raw HAR reads expose only those sanitized bytes. Explicit placeholders remain permitted. Direct filesystem edits are outside the MCP ingress policy and may be included by the next notes snapshot, so do not place credentials directly under `notes/`. Detection is defense in depth, not a guarantee that every possible secret format can be recognized, and it does not remove credentials already present in earlier Git history. Rotate and purge any previously committed secret separately. |
| **No caller-selected command execution** | `GitRepository` is the only subprocess boundary. It launches hardcoded `/usr/bin/git` directly—never a shell—with programmatically built arguments, `-C` for the fixed vault URL, and `--` before the fixed `notes` pathspec. Inherited `GIT_*` variables are removed so callers cannot redirect the repository, worktree, index, or configuration. Prompts and paging are disabled; commit hooks are disabled with `core.hooksPath=/dev/null`, signing is disabled, and the local author identity and constant snapshot subject are supplied by the application. Standard output is discarded and standard error is bounded to 32 KiB. Trusted repository configuration, including clean filters invoked by `git add`, remains part of the local Git trust boundary. |
| **No hard deletes of user content** | `delete_file` moves files to a collision-proof recoverable name under a real, non-symlink `.trash/` directory; `removeItem` is never called on user content. |
| **Stale cooperating note edits are rejected** | Reads under `notes/` return a SHA-256 identity of the bytes observed during the protected read. Updates and deletes require that opaque revision and compare it again under an exclusive per-path lease; conflicts never disclose a replacement token that could enable blind retry. Applications outside this MCP protocol do not honor its locks, so their writes are rechecked but cannot participate in an atomic cross-application compare-and-swap. |
| **Directory moves are atomic, contained, and no-clobber** | `move_directory` accepts only proper non-hidden, non-package subtrees of `notes/`, rejects symbolic-link components and self-subtree destinations, opens every descendant path component with `O_NOFOLLOW`, and uses `renameatx_np(..., RENAME_EXCL)` so an existing destination is never overwritten. Every regular file is hashed through one stable descriptor under aggregate count/byte ceilings and receives the persisted-file policy, including structured HAR credential checks and strict encoding for obvious text/configuration paths. After the atomic rename, the operation requests a shared notes snapshot. Other agents' pending note changes may deliberately join that recovery point; files outside `notes/` cannot. |
| **Concurrent MCP clients coordinate only the state they share** | Fair actor-based reader/writer leases coordinate tasks in one runtime; persistent shared/exclusive advisory locks enforce the same path exclusion across independent MCP processes. A vault-wide shared/exclusive notes-tree lease makes a directory rename exclude every cooperating note read or write, while ordinary unrelated file operations retain path-level concurrency. Lock-file naming is a same-version cooperating-host protocol, so an upgrade requires fully stopping and restarting every MCP host for the vault; mixed old/new hosts are not supported. OS record-lock polling does not guarantee strict cross-process FIFO order. Unrelated note persistence may overlap. Only `GitRepository` owns the cross-process `vault-versioning.lock`, which covers its complete init–stage–check–commit sequence and prevents `.git/index.lock` races. Ordinary reference reads remain concurrent; expensive direct PDF snapshot/PDFKit reads share a bounded local queue and vault-scoped cross-process permit. |
| **Broad search is bounded and does not create a disclosure bypass** | `search_vault` enumerates only registered textual formats under `notes/` and PDFs under `references/`; it skips hidden, packaged, symlinked, non-regular, unsupported, and unavailable cloud entries, then resolves every candidate through the contained target boundary. Live note snapshots use shared path leases, stable no-follow descriptors, and aggregate byte/projection/section ceilings. PDF body search uses a derived per-vault SQLite/FTS5 index outside the vault: current descriptor identity invalidates changed rows, extraction hashes one immutable private snapshot, validates title/labels/page text before atomic publication, and removes a formerly safe row if its current revision violates sensitive-content policy. The private quota is a conservative peak envelope for the database, WAL, and shared-memory sidecar: the main file reserves transaction headroom, bounded publication representations are checked before `BEGIN`, and WAL is checkpointed around commits. FTS input is generated from bounded normalized tokens, corrupt or incompatible derived data is rebuilt only after the complete bundle passes ownership/link checks, and an unrecoverable index fails closed instead of triggering an unbounded live-library fallback. Warm opens perform bounded application/schema/generation/table/FTS probes; exhaustive canonical-to-FTS verification runs on creation and rebuild and is available as an explicit diagnostic, but ordinary warm opens intentionally trust the private derived cache after their bounded probes. PDF extraction shares bounded local and cross-process admission with direct PDF reads; page/text/candidate limits, a combined retained-representation ceiling, streaming term normalization, and autorelease pools bound one indexing job. Search never stores rendered pages or performs implicit OCR. Smart matching completes a corpus-wide literal pass before fair relaxed work; caller queries are literal data, never regexes, SQL, or subprocess arguments. Traversal, fields, formats, prefixes, tokens, comparisons, candidates, snippets, cursors, diagnostics, and the complete MCP wire response remain capped. Cursors bind current admitted revisions and projection outcomes. HAR is sanitized before matching, every returned field is revalidated, and unsafe content contributes only bounded counters—not values or query-dependent diagnostics. Structured MCP values and JSON encoding keep all returned vault data untrusted. |
| **Timed-out mutations are idempotent without globally blocking the vault** | Every mutation requires a caller-generated UUID. Durable receipts replay only the exact same request, reject identifier reuse, and record an intent followed by a `persistenceStarted` state before bytes may change. An uncertain crash fails closed only for that mutation ID; unrelated mutations continue. Exact post-persistence recovery validates the stored outcome before requesting another snapshot. Receipts are never auto-pruned: a hard 65,536-record / 512 MiB reservation quota refuses new IDs before persistence while preserving every retained exact replay. A short cross-process receipt-update lock protects quota and receipt metadata only; identity locks remain striped and note persistence does not occur while that shared bookkeeping lock is held. Any receipt export/removal is an explicit administrative action that also removes the corresponding replay guarantee. |
| **Git records recoverable notes snapshots, not agent ownership** | `VaultMutationExecutor` orders persistence → `VaultVersioning.recordSnapshot()` → receipt, completes post-persistence recovery work even if the request is canceled, and propagates snapshot failures instead of swallowing them. `GitRepository` stages and commits only `notes/`; `references/` and unrelated staged paths remain outside the snapshot. A snapshot may coalesce pending changes from several agents, and a later request succeeds as a no-op when its state was already captured. Exact retry validates the persisted outcome before requesting a snapshot again. Sudden machine or storage power loss is outside the transaction guarantee because vault bytes, Git objects/refs, and external receipts are not jointly journaled and synchronized. |
| **Optional read-only mode** | `--read-only` exposes `read_file` and `search_vault`, hides file and directory mutation tools, removes mutating operations from capability discovery, rejects direct calls at both frontend and backend boundaries, and skips Git initialization. |

## Network activity

The server contains no network client and requests no outbound network operation in normal use.

- **Transport:** `StdioTransport` only — it reads stdin and writes stdout. The server never
  instantiates a network transport.
- **The MCP SDK ships HTTP/SSE transports** (pulled in via `swift-nio` and `eventsource`); that code
  is compiled into the binary but is **never instantiated or invoked** by SecondBrainMCP.
- **Git** is asked to run only local `init`, `add`, `diff`, `ls-files`, and `commit` operations
  against the vault. The server never requests `push`, `fetch`, or `remote`. Commit hooks and signing
  are disabled. Trusted repository configuration, including clean filters used while staging notes,
  may still execute local programs and remains outside this network claim.
- **PDFKit** is a macOS system framework and performs no network activity here. Broad search uses immutable in-memory snapshots; direct PDF reads stream the stable vault descriptor into a private, bounded temporary copy before PDFKit reopens it.

You don't have to take that on faith — see [Verifying](#verifying-it-yourself) below.

## Dependencies

One direct dependency (the MCP SDK); the rest are transitive and come from Apple's open-source Swift
libraries. All are version-pinned in `Package.resolved` (committed), so `swift build` never silently
pulls new versions. The table below reflects the committed lockfile — regenerate any time with
`swift package show-dependencies`.

| Package | Owner | Version | Role |
|---------|-------|---------|------|
| `modelcontextprotocol/swift-sdk` | MCP org (Anthropic) | 0.12.0 | **Direct** — MCP protocol library |
| `apple/swift-log` | Apple | 1.10.1 | Logging to stderr |
| `apple/swift-system` | Apple | 1.6.4 | Low-level system calls |
| `apple/swift-nio` | Apple | 2.95.0 | Async I/O (used by the SDK's HTTP transport — not by this server) |
| `apple/swift-collections` | Apple | 1.4.0 | Data structures |
| `apple/swift-atomics` | Apple | 1.3.0 | Thread-safe primitives |
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

**Confirm the running server opens zero network sockets** (two terminals):

```bash
# Terminal 1 — start the server (the `sleep` keeps stdin open so it doesn't exit on EOF)
sleep 999 | .build/release/second-brain-mcp --vault /path/to/your/vault

# Terminal 2 — inspect this process's sockets, then clean up
PID=$(pgrep -x second-brain-mcp | head -1)
lsof -i -a -p "$PID"        # empty output = no TCP/UDP/IPv4/IPv6 sockets
kill "$PID" 2>/dev/null; pkill -f 'sleep 999' 2>/dev/null
```

**Audit the dependency graph and scan the SDK source for phone-home code:**

```bash
swift package show-dependencies
grep -ri 'telemetry\|analytics\|tracking\|beacon\|phone.home' .build/checkouts/
```

## Dependency update policy

Updates are deliberate, never automatic — a new transitive dependency could introduce network calls
or telemetry, so each update is audited before it lands.

1. Branch — never update on `main`.
2. `swift package update`, then review `git diff Package.resolved` and `swift package show-dependencies`.
3. Re-run the telemetry grep and the `lsof` network check above.
4. `swift test`.
5. Merge only after all checks pass.
