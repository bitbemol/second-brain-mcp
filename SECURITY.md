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
| **MCP-prepared credentials are rejected before persistence** | Every textual create/update prepared through the MCP boundary is scanned for strong bearer, authorization, cookie, token-assignment, private-key, JWT, and provider-token signals. Directory moves validate every existing descendant before rename. Rejections report only the detector and line, never the matched value. HAR imports additionally replace known authorization/cookie headers, cookies, URL user information, authentication parameters, and credential fields in JSON/form request bodies with `[REDACTED]`; raw HAR reads expose only those sanitized bytes. Explicit placeholders remain permitted. Direct filesystem edits are outside the MCP ingress policy and may be included by the next notes snapshot, so do not place credentials directly under `notes/`. Detection is defense in depth, not a guarantee that every possible secret format can be recognized, and it does not remove credentials already present in earlier Git history. Rotate and purge any previously committed secret separately. |
| **No caller-selected command execution** | `GitRepository` is the only subprocess boundary. It launches hardcoded `/usr/bin/git` directly—never a shell—with programmatically built arguments, `-C` for the fixed vault URL, and `--` before the fixed `notes` pathspec. Inherited `GIT_*` variables are removed so callers cannot redirect the repository, worktree, index, or configuration. Prompts and paging are disabled; commit hooks are disabled with `core.hooksPath=/dev/null`, signing is disabled, and the local author identity and constant snapshot subject are supplied by the application. Standard output is discarded and standard error is bounded to 32 KiB. Trusted repository configuration, including clean filters invoked by `git add`, remains part of the local Git trust boundary. |
| **No hard deletes of user content** | `delete_file` moves files to a collision-proof recoverable name under a real, non-symlink `.trash/` directory; `removeItem` is never called on user content. |
| **Stale cooperating note edits are rejected** | Reads under `notes/` return a SHA-256 identity of the bytes observed during the protected read. Updates and deletes require that opaque revision and compare it again under the global exclusive mutation lease; conflicts never disclose a replacement token that could enable blind retry. Applications outside this MCP protocol do not honor its lock, so their writes are rechecked but cannot participate in an atomic cross-application compare-and-swap. |
| **Directory moves are atomic, contained, and no-clobber** | `move_directory` accepts only proper non-hidden, non-package subtrees of `notes/`, rejects symbolic-link components, self-subtree destinations, and case- or Unicode-equivalent source/destination paths, opens every descendant path component with `O_NOFOLLOW`, and uses `renameatx_np(..., RENAME_EXCL)` so an existing destination is never overwritten. Every regular file is hashed through one stable descriptor under aggregate count/byte ceilings and receives the persisted-file policy, including structured HAR credential checks and strict encoding for obvious text/configuration paths. The global mutation lease remains held through the atomic rename and required notes snapshot. Other agents' pending note changes may deliberately join that snapshot; files outside `notes/` cannot. |
| **Concurrent MCP clients share one vault access boundary** | One writer-preferring `VaultAccessCoordinator` per runtime grants shared read leases and one global exclusive mutation lease. Existing reads finish before a mutation starts; once a mutation waits, later reads wait behind it. The mutation lease covers the entire validation, preparation, filesystem, and Git chain. Independent MCP processes use shared/exclusive modes on the same advisory lock file; OS record-lock polling does not guarantee strict FIFO order between processes. Lock-file naming is a same-version cooperating-host protocol, so an upgrade requires fully stopping and restarting every MCP host for the vault. Expensive direct PDF reads and PDF search extraction additionally share a bounded local queue and vault-scoped cross-process permit. |
| **Search locates content without becoming a read bypass** | `search_vault` selects exactly one structural area and enumerates only globally registered readable textual formats plus registered custom atom providers such as PDF. Hidden entries, symbolic links, non-regular files, unsupported extensions, and paths that fail the contained `ReadableFileTarget` boundary are not searched. Note bytes are captured through the same stable no-follow snapshots and global shared read lease; each file remains subject to its global format-size policy. Results contain only the global format, vault-relative path, and optional physical PDF page—never snippets, matched content, diagnostics derived from content, or mutation revisions. Caller queries are literal data, never regexes, SQL, or subprocess arguments. Tags and created dates reuse normalized Markdown frontmatter and are available only in `notes`. PDF page text is revision-keyed derived data in the private per-vault application-support directory; embedded PDFKit text is preferred and Vision OCR is used only when embedded text is absent. PDF extraction shares bounded admission with direct PDF reads, checks cancellation between pages, and never caches rendered page images. Cursor inputs and result counts are capped, and cursors are bound to the normalized location and criteria. Returned paths remain untrusted input to the subsequent validated `read_file` call. |
| **Lost mutation responses require observation** | Mutations do not accept an idempotency key and are not replayed automatically. A normal call returns only after persistence and any required snapshot finish. If the transport loses that response, the caller must use `read_file` or another validated observation before deciding whether to issue a new mutation. A process or machine failure can still occur between vault persistence and Git durability because those filesystem states are not one journaled transaction. |
| **Git records recoverable notes snapshots, not agent ownership** | `VaultMutationExecutor` orders persistence → `VaultVersioning.recordSnapshot()`, finishes that chain after persistence starts even if the caller is canceled, and propagates snapshot failures instead of swallowing them. `GitRepository` stages and commits only `notes/`; `references/` and unrelated staged paths remain outside the snapshot. A snapshot may coalesce pending changes from several agents, and a later snapshot request succeeds as a no-op when its state was already captured. |
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
- **PDFKit and Vision** are macOS system frameworks and perform no network activity here. PDF search uses stable in-memory snapshots and stores only revision-keyed derived page text under the private application-support directory; direct PDF reads stream the stable vault descriptor into a private, bounded temporary copy before PDFKit reopens it.

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
