---
name: second-brain-development
description: Repository-specific workflow for implementing, debugging, testing, reviewing, or documenting SecondBrainMCP. Use for Swift source or test changes, MCP schemas and tools, file formats, vault storage, search, path validation, mutation/Git/audit sequencing, concurrency, media/PDF handling, dependencies, architecture, security, and public behavior in this repository.
---

# Second Brain Development

Apply this workflow together with the root `AGENTS.md`. Use Xcode MCP for every project-file operation and for build, diagnostics, and tests.

## Prepare the task

1. Read only the relevant source-of-truth material:
   - Read `CLAUDE.md` sections on architecture, guardrails, critical rules, and the affected feature.
   - Read `README.md` when behavior, setup, tool schemas, resources, or capability discovery can change.
   - Read `SECURITY.md` for path handling, external files, secrets, subprocesses, dependencies, or threat-boundary changes.
   - Read `Package.swift` and `Package.resolved` only for target, platform, or dependency work.
2. Inspect current Xcode diagnostics and identify the narrowest relevant tests before editing.
3. Trace the affected path end to end. Do not patch one layer while leaving its contracts or tests inconsistent.

## Route work by boundary

- Put CLI parsing and startup in `Frontend/Application` or `Frontend/Configuration`.
- Put MCP lifecycle, schemas, decoding, and output mapping in `Frontend/MCP`; never leak MCP types into Backend or Shared.
- Put stable cross-boundary request, result, format, capability, and logging contracts in `Shared`; keep policy and orchestration out.
- Put file ingress, routing, operations, storage, targets, transactions, and validation in their corresponding `Backend/Files` areas.
- Keep search outside CRUD. Preserve bounded snapshots, extraction, stable ranking, structured locators, and shared scan permits.
- Keep image, video, and PDF work in-process under Backend media/format boundaries. Do not add another subprocess site.
- Locate tests by the same feature or invariant, and prefer focused assertions at the layer that owns the behavior.

## Implement safely

1. Validate at ingress and convert untrusted values into owned, constrained domain types.
2. Require explicit concrete formats and use exhaustive switches. Reject malformed or unsupported input instead of silently repairing it.
3. Keep handlers pure with respect to persistence: prepare or interpret bytes, then let stores and transaction owners perform mutations.
4. Preserve structural write boundaries, external-source immutability, credential screening, soft deletion, exact-byte revisions, and mutation-id replay semantics.
5. Preserve actor isolation, `Sendable` correctness, path leases, cross-process locks, cancellation boundaries, and explicit error propagation.
6. Make the smallest coherent change and match surrounding Swift style. Avoid speculative abstractions and unrelated cleanup.

## Use the specialized checklist

### File format or capability

- Update the concrete format and public capability only when the storage format is truly new.
- Bind each operation explicitly; do not expose internal handler identities.
- Cover extension/content mismatches, malformed data, area permissions, read output, mutation behavior, and capability discovery.
- Update the public format/tool documentation.

### MCP schema or public tool

- Keep schemas explicit, bounded, and backwards-compatible unless the user requested a breaking change.
- Update decoders, Shared contracts, controllers, mappings, capability resources, and integration tests together.
- Verify stdout remains pure JSON-RPC and update `README.md`.

### Path, mutation, Git, audit, or concurrency

- Treat this as high risk.
- Exercise traversal, symlink and prefix-confusion failures; notes/reference boundaries; stale revisions; duplicate and conflicting mutation IDs; cancellation; Git failure; audit/receipt ordering; and concurrent access as applicable.
- Run the security-focused tests, relevant transaction tests, full Xcode test plan, and Xcode build.

### Search

- Preserve result, snippet, comparison, projection, response, and memory ceilings.
- Verify stable ranking, section semantics, reference safety, structured canvas locators, cancellation, and concurrent scan limits.
- Keep search independent from mutation revisions and CRUD routing.

### Dependency or toolchain

- Do not update dependencies without explicit user authorization.
- Review direct and transitive changes, `Package.resolved`, telemetry/network implications, subprocess behavior, and the security audit procedure.
- Run the full Xcode test plan and verify a release build path compatible with the documented symlink.

## Verify and hand off

- Refresh diagnostics after edits and fix every relevant new warning or error.
- Run focused tests first; use the root verification matrix to decide when the full plan and build are mandatory.
- Inspect Xcode's project structure after every create, move, rename, or delete.
- Review the final diff for leaked secrets, accidental API changes, generated files, missing docs, and orphaned references.
- Report changed behavior, files, tests/builds run, their results, and any residual risk or skipped verification.
