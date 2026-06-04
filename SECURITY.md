# Security

SecondBrainMCP runs **locally** as a subprocess of an MCP client (e.g. Claude Desktop or Claude
Code), communicating only over stdin/stdout (`StdioTransport`). It has read/write access to a
Markdown note vault and read-only access to a PDF library. Because it touches personal files,
security is treated as a design constraint, not a feature.

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
- **Not trusted:** the *arguments* of individual tool calls. Paths, refs, and messages are treated
  as hostile input and validated/rejected — a buggy or adversarial caller must not be able to read
  or write outside the vault, run arbitrary commands, or permanently destroy data.
- **Out of scope:** what the MCP client does with vault data after the server returns it (that is
  governed by the client and the AI provider's own terms), and physical/OS-level access to the machine.

## Security posture

| Guarantee | How it's enforced |
|-----------|-------------------|
| **No path escapes the vault** | Every note path goes through `PathValidator`: rejects absolute paths, screens for `..` (incl. percent-encoded / Unicode dots) before and after resolution, resolves symlinks, and asserts containment within the vault root. Exhaustively tested in `PathValidatorTests`. |
| **References are read-only by construction** | `ReferenceManager` has **zero** write methods — it is structurally impossible to modify `references/` through the server, not merely disabled by a flag. |
| **No arbitrary shell execution** | The only subprocesses are `/usr/bin/git` and `/usr/bin/grep`, at hardcoded paths, invoked with programmatically built argument arrays and `--` guards. No user input is ever interpolated into a command. Commit messages and git refs are sanitized to a safe character allowlist. |
| **No hard deletes of user content** | `delete_note` moves files to `.trash/<timestamp>_<name>`; `removeItem` is never called on user content. |
| **Full history of every write** | Every note write is auto-committed to git, so any change is reviewable and revertible. |
| **Optional read-only mode** | `--read-only` un-registers all write/delete/revert tools so the client never even sees them. |

## Network activity

The server makes **zero outbound network connections** in normal operation.

- **Transport:** `StdioTransport` only — it reads stdin and writes stdout. The server never
  instantiates a network transport.
- **The MCP SDK ships HTTP/SSE transports** (pulled in via `swift-nio` and `eventsource`); that code
  is compiled into the binary but is **never instantiated or invoked** by SecondBrainMCP.
- **Git** runs only local operations (`init`, `add`, `commit`, `log`, `show`, `checkout`) against
  the vault. The server never runs `push`, `fetch`, or `remote` — it does not contact a git remote,
  even if the vault has one configured.
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
Vault (local disk)
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
