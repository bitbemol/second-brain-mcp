# Second Brain MCP agent policy

This is the always-on repository contract. Keep it short, durable, and action-oriented. Product
behavior belongs in `README.md`; threat and dependency policy belongs in `SECURITY.md`; implementation
details belong in code and tests.

## Load only what the task needs

- Read `README.md` when public behavior, setup, tools, formats, or discovery can change.
- Read `SECURITY.md` for paths, external files, credentials, subprocesses, dependencies, or trust
  boundaries. Read `Package.swift` and `Package.resolved` only for targets, platforms, or dependencies.
- Prefer the affected implementation and focused tests over broad background reading. Do not load
  unrelated documentation or duplicate volatile facts here.

## Required Xcode workflow

- Use Xcode MCP for discovery, reading, searching, project-file creation and mutation, structure,
  diagnostics, builds, and tests whenever it covers the operation.
- Do not mutate project files with shell-writing commands, `apply_patch`, or Git restore/checkout/
  reset/clean. If Xcode cannot represent a required mutation, obtain explicit user permission before
  a direct-filesystem fallback.
- Read-only Git inspection is allowed. Preserve unrelated changes and do not stage, commit, push,
  update dependencies, or perform broad rewrites unless requested.
- Treat `.swiftpm/xcode` and `.build` as generated data; never edit them directly.

## Architecture boundaries

- Dependencies flow `Frontend -> Backend -> Shared`. MCP types stay in `Frontend/MCP`; Backend and
  Shared never import MCP.
- Frontend owns CLI/startup, MCP lifecycle, schemas, strict decoding, controllers, and output mapping.
  Backend owns policy, filesystem work, search, media/PDF processing, concurrency, and persistence.
  Shared contains only stable cross-boundary values, protocols, formats, capabilities, and logging.
- Keep the executable/product identity `second-brain-mcp`; tests import its Swift module as
  `second_brain_mcp`. A differently named executable target can build in SwiftPM while failing in Xcode.
- File CRUD remains catalog-driven. `FileFormat` describes concrete storage formats, not semantic roles.
  Operation bindings and areas are explicit and exhaustive; public schemas derive from the catalog.
- Keep listing, content search, link queries, and path moves as narrow ports outside atomic file CRUD.
  Keep format handlers persistence-free: they prepare or interpret bytes, then stores and transaction
  owners perform mutations.
- Put system-framework code behind narrow protocols in the layer that needs it. Do not create manager-
  shaped dependency bags or speculative abstractions.

## Non-negotiable safety and state rules

- Reserve stdout exclusively for JSON-RPC. Send lifecycle logs and diagnostics to stderr.
- Route every caller-controlled vault path through `PathValidator` and the appropriate readable or
  writable target. Require the declared concrete format to agree with extension and content.
- `references/` is structurally read-only. Writes and moves are limited to supported content under
  `notes/`; user deletion is always recoverable movement into `.trash/`, never permanent removal.
- `create_file` is the only public operation that may read an external source. External sources are
  canonicalized, regular-file-only, bounded, immutable, outside the vault, and copied through a stable
  descriptor snapshot before decoding.
- Text prepared through MCP is credential-screened before persistence. HAR redaction is the explicit
  transformation exception. Never include secret values in errors or logs.
- Validated canonical Apple Git is the only product subprocess. Reject `/usr/bin/git` shims; require
  a canonical regular executable satisfying `identifier "com.apple.git" and anchor apple`, and probe
  it inside the sandbox. Snapshots use a product-owned bare repository, UUID-isolated index, unique
  private ref, and dedicated cross-process lock outside the vault. Never inspect, initialize, change,
  unlock, repair, or wait for user Git state. Disable inherited configuration, attributes, filters,
  hooks, signing, and maintenance; bound the complete snapshot attempt and terminate its process group
  on timeout. Never add caller-selected commands, shells, or another product subprocess site.
- `VaultMutationExecutor` owns prepared persistence followed by required
  `VaultVersioning.recordSnapshot()` under the global exclusive vault mutation lease. Keep the lease
  through persistence and snapshot; propagate snapshot failure even if bytes already changed.
- Reads under `notes/` return exact-byte revisions. Update, delete, continuation reads, and file moves
  compare the supplied revision at the protected boundary. There is no mutation replay/idempotency
  token: after a lost response, observe current state before deciding whether to retry.
- Preserve writer-preferring shared/exclusive vault coordination and the cross-process advisory lock.
  Queues must keep constant-time cancellation removal and amortized constant-time dequeue; do not
  reintroduce array front-removal or full-queue scans.
- Capture a readable file once per protected operation and use that immutable snapshot throughout.
  Keep preparation separate from persistence and check cancellation before expensive or queued work.
- Writable startup connects transport before one-shot pending Git recovery. Recovery holds a shared
  vault lease plus the dedicated snapshot lock, so reads and discovery remain available while a
  mutation waits at the exclusive vault boundary for the active attempt. Every snapshot-requiring
  mutation must durably snapshot its validated pre-change footprint before persistence; preflight
  failure is not applied. Never restart full recovery from a tool call.
- Only explicitly audited `CallerSafeError` values may cross the MCP boundary verbatim. Unknown Cocoa,
  POSIX-wrapper, or internal errors receive stable generic messages without absolute paths.
- Reject malformed or unsupported input; do not silently repair, infer hidden defaults, or weaken a
  structural constraint for convenience.

## Bounded agent-facing operations

- Text content reads validate the complete stored document, return bounded UTF-8 windows, never split a
  scalar, and require the same revision for continuation.
- `search_vault`, `list_files`, and `query_links` return locators or bounded metadata, never
  snippets or bodies. Preserve request/corpus-bound cursors, real-anchor validation, deterministic
  ordering, stale-cursor rejection, cancellation, and limits defined by their request-limit types.
- Directory enumeration must stop before retaining data beyond scan ceilings. Do not restore eager
  unbounded directory arrays, sort every dense match, rescan once per repeated query token, or format
  expensive metadata for entries outside the returned page.
- Canvas search atoms retain node and field identity. PDF search uses one atom per physical page;
  derived text is revision-keyed outside the vault and never mutation authority.
- PDF/image/video work remains in-process and bounded. Inspect dimensions, frame counts, pages, and
  aggregate output before expensive decoding or rendering. Keep admission control, autorelease scopes,
  and cooperative cancellation; never cache rendered PDF page images. Direct PDF reads acquire their
  shared PDF permit before the vault lease and snapshot. Search releases the vault lease before PDF
  admission and never reacquires it during extraction.
- Metadata view and content selectors remain mutually exclusive. Metadata reads must not return
  Markdown bodies, PDF page text, or images.

## Strict test-driven changes

- For every behavior change or bug fix, add or update a focused test first. Model observable behavior
  and the failure path, not private implementation.
- Run it against the current implementation and confirm the intended behavioral failure. Compiler
  errors, broken fixtures, or unrelated infrastructure failures do not count as red.
- Only then implement the smallest coherent change, rerun to green, and keep the regression test.
- If no practical automated boundary exists, explain why and obtain explicit user agreement before
  implementation. Documentation-only, configuration, and behavior-preserving refactors do not require
  a manufactured red, but still require applicable verification.
- Tests use temporary vaults and never user content.

## Change workflow

1. Establish scope through Xcode; inspect the implementation, callers, tests, and current diagnostics.
2. Trace the complete affected path: MCP/CLI ingress, Shared contract, Backend policy, storage/search,
   then output. For structural changes, inspect references and usages before editing.
3. Complete the required red phase, make the smallest explicit change, and run the focused test green.
4. Check adjacent security, concurrency, cancellation, cursor, and failure behavior proportional to risk.
5. Synchronize only the owning documentation: public contract in `README.md`, security/dependencies in
   `SECURITY.md`, and durable agent workflow or architecture rules here.
6. Inspect Xcode structure, diagnostics, and the final Git diff. Report missing/orphaned files,
   unexpected untracked files, unresolved references, and verification not run.

## Risk-based verification

- Documentation or harness-only: confirm Xcode visibility, references, and affected configuration.
- Localized Swift: refresh diagnostics and run the smallest relevant test group.
- Cross-layer, concurrency, path-security, mutation, Git, search bounds, MCP schema, startup, or public
  contract: focused tests, then the full Xcode test plan and an Xcode build.
- Dependency or toolchain: explicit authorization, `Package.resolved` and security audit, full test
  plan, and release build through the documented `.build/release/second-brain-mcp` symlink.
- Any relevant failing test, new diagnostic, broken reference, stale documentation, or leaked internal
  path is incomplete work.
