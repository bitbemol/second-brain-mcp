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
| **High-confidence credentials do not enter Git history** | Every prepared textual create/update is scanned before persistence for strong bearer, authorization, cookie, token-assignment, private-key, JWT, and provider-token signals. External text changes included by the automatic startup snapshot and commit-only recovery receive the same check. Rejections report only the detector and line, never the matched value. HAR imports additionally replace known authorization/cookie headers, cookies, URL user information, authentication parameters, and credential fields in JSON/form request bodies with `[REDACTED]`; raw HAR reads expose only those sanitized bytes. Explicit placeholders remain permitted. This is defense in depth, not a guarantee that every possible secret format can be recognized, and it does not remove credentials already present in earlier Git history. Rotate and purge any previously committed secret separately. |
| **No caller-selected command execution** | The server directly launches only `/usr/bin/git` at a hardcoded path, with programmatically built argument arrays, literal pathspec mode, and `--` guards. Inherited `GIT_*` variables are removed so callers cannot redirect the repository, worktree, index, or configuration. No user input is interpolated into a command. Commit messages are sanitized to a safe character allowlist. Git still honors extension points configured by the trusted local user, such as hooks, signing, and filters. |
| **No hard deletes of user content** | `delete_file` moves files to a collision-proof recoverable name under a real, non-symlink `.trash/` directory; `removeItem` is never called on user content. |
| **Stale cooperating note edits are rejected** | Reads under `notes/` return a SHA-256 identity of the bytes observed during the protected read. Updates and deletes require that opaque revision and compare it again under an exclusive per-path lease; conflicts never disclose a replacement token that could enable blind retry. Applications outside this MCP protocol do not honor its locks, so their writes are rechecked but cannot participate in an atomic cross-application compare-and-swap. |
| **Concurrent MCP clients cannot interleave note mutations** | Fair actor-based reader/writer leases coordinate tasks in one runtime; persistent shared/exclusive advisory locks enforce the same path exclusion across independent MCP processes. OS record-lock polling does not guarantee strict cross-process FIFO order. A vault-wide process lock also protects the shared Git index and commit sequence. Read-only reference/PDF access remains concurrent. |
| **Broad search is bounded and does not create a disclosure bypass** | `search_vault` enumerates only supported textual files under `notes/`, skips hidden, symlinked, non-regular, unsupported, and not-currently-downloaded ubiquitous entries, then resolves every candidate through the existing contained target boundary. Each note is snapshotted under a shared path lease; matching happens after release and returns no mutation revision. A cancellation-aware single-permit gate prevents concurrent scans from multiplying the corpus ceiling. Queries are literal data—never regular expressions or subprocess arguments—and query/prefix collections, traversal, aggregate bytes, Markdown lines/front matter/tags, sections, source tokens, general and fuzzy comparisons, edit-distance cells, candidates, metadata, snippets, and the complete encoded response are capped. Canvas searches only projected node values. HAR is sanitized before matching; every other textual snapshot and final projection passes the sensitive-content policy. Unsafe files contribute only bounded skip counts, not values or query-dependent diagnostics. Structured MCP values and JSON encoding keep snippets as untrusted strings. |
| **Timed-out mutations are idempotent** | Every mutation requires a caller-generated UUID. Durable receipts replay only the exact same request, reject identifier reuse, and record an in-progress intent before persistence so an interrupted process does not apply the request twice. After an ordinary process crash, a surviving active marker blocks other mutations and permits only conservative exact-request recovery. |
| **Scoped Git history for completed mutations** | `VaultMutationExecutor` orders persistence → Git commit → best-effort audit → receipt, completes the critical phase after persistence even if the request is canceled, and propagates commit failures instead of swallowing them. A durable active marker prevents later mutations from blurring a failed commit and permits commit-only retry with the original mutation ID. Sudden machine or storage power loss is outside the transaction guarantee because vault bytes, Git objects/refs, and external receipts are not jointly journaled and synchronized. |
| **Optional read-only mode** | `--read-only` exposes `read_file` and `search_vault`, hides mutating tools, removes mutating operations from capability discovery, rejects direct calls at both frontend and backend boundaries, and skips vault migration and Git initialization. |

## Network activity

The server contains no network client and requests no outbound network operation in normal use.

- **Transport:** `StdioTransport` only — it reads stdin and writes stdout. The server never
  instantiates a network transport.
- **The MCP SDK ships HTTP/SSE transports** (pulled in via `swift-nio` and `eventsource`); that code
  is compiled into the binary but is **never instantiated or invoked** by SecondBrainMCP.
- **Git** is asked to run only local operations (`init`, `add`, `commit`, `status`) against
  the vault. The server never requests `push`, `fetch`, or `remote`. Git hooks, signing programs,
  filters, and similar extensions configured by the trusted local user remain outside this claim.
- **PDFKit** is a macOS system framework and performs no network activity here.

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
