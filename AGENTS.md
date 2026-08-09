# Second Brain MCP agent policy

## Sources of truth

- Treat this file as the always-on operating contract.
- Use `$second-brain-development` for implementation, debugging, testing, review, architecture, security, dependency, or public-API work in this repository.
- Read the relevant sections of `CLAUDE.md` before code changes; it is authoritative for architecture, invariants, and conventions.
- Use `README.md` for the public product contract and setup, `SECURITY.md` for threat and dependency policy, and `Package.swift` for targets and dependencies. Do not duplicate those documents here.

## Required Xcode workflow

- Use Xcode MCP tools for discovery, reading, searching, creation, editing, moving, renaming, and deletion of files or directories represented in the active Xcode workspace.
- Do not mutate project files with `apply_patch`, shell redirection, `sed -i`, `perl -i`, `cp`, `mv`, `rm`, `touch`, `mkdir`, `tee`, or Git restore/checkout/reset/clean commands.
- Use Xcode build, test, diagnostics, documentation, snippet, and preview tools whenever they cover the task.
- Read-only Git inspection such as status, diff, and log is allowed. Never use Git as a substitute for an Xcode file operation.
- If Xcode MCP is unavailable, the workspace is not open, or Xcode cannot represent the required operation, stop and obtain explicit user permission before a direct-filesystem fallback.
- Preserve unrelated user changes. Do not stage, commit, push, update dependencies, or perform broad mechanical rewrites unless requested.

## Load-bearing invariants

- Keep dependencies flowing `Frontend -> Backend -> Shared`; keep MCP types inside `Frontend/MCP`.
- Reserve stdout for JSON-RPC. Send logs and diagnostics to stderr.
- Route every caller-controlled path through `PathValidator` and the appropriate readable or writable target.
- Keep `references/` structurally read-only and restrict writes to supported content under `notes/`.
- Never add caller-selected command execution. `GitRepository` and `/usr/bin/git` remain the only subprocess boundary.
- Preserve soft-delete behavior; user content moves to `.trash/` and is never permanently deleted.
- Keep preparation separate from persistence. `VaultMutationExecutor` owns persistence, Git, audit, and receipt sequencing under the operation coordinator's leases.
- Preserve exact-byte revisions, mutation-id idempotency, bounded search, cancellation behavior, and strict Swift concurrency unless a reviewed design explicitly replaces them.

## Change workflow

1. Establish scope and inspect the relevant implementation, callers, tests, and current diagnostics through Xcode.
2. Trace the complete boundary affected by the request before editing: MCP/CLI ingress, Shared contract, Backend policy, persistence or search, then output.
3. Make the smallest coherent change. Prefer explicit types, exhaustive switches, structural constraints, and rejection of invalid input over hidden defaults or repair.
4. Add or update focused tests with the implementation. Use temporary vaults and verify externally observable behavior and failure paths.
5. Synchronize documentation: public behavior in `README.md`, security or dependency posture in `SECURITY.md`, architecture or durable gotchas in `CLAUDE.md`, and recurring agent workflow lessons in this policy or the repo skill.
6. Inspect the final Xcode project structure and diff. Report unresolved references, missing files, unexpected untracked files, suspected orphans, and any verification not run.

## Verification matrix

- Documentation or harness-only changes: confirm Xcode visibility and validate the affected configuration; a Swift build is not required.
- Localized Swift changes: refresh Xcode diagnostics and run the smallest relevant test group.
- Cross-layer, concurrency, path-security, mutation, Git/audit, search-bounds, MCP-schema, startup, or public-contract changes: run focused tests, then the full Xcode test plan and an Xcode build.
- Dependency or toolchain changes: review `Package.resolved`, follow the audit in `SECURITY.md`, run the full test plan, and verify a release build.
- Treat any failing relevant test, new error diagnostic, reference inconsistency, or documentation mismatch as incomplete work.

## Structural-change checks

- Before deleting, moving, or renaming content, inspect Xcode project references and relevant usages.
- After structural changes, confirm the result in Xcode's project structure and run risk-appropriate diagnostics/tests.
- Treat `.swiftpm/xcode` and `.build` as generated workspace data; do not edit them directly.
