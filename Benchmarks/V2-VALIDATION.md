# v2 validation record

Status: release-candidate verification in progress; not a publication approval.
Measurements use generated temporary vaults, never user content. This record is
separate from the public API contract in the root README.

## Acceptance-report fixes (2026-08-27)

Source baseline: `0f61818737a65c41d58c77a342f555d32f54e701` on `main`.
Runtime and regression changes are recorded in focused commits `8e91b94` through
`35a5384` on `main`. No branch, dependency update, push, or release is part of this round.
Baseline release SHA-256: `9e4ef65778cb6944449eee1d22b94aad9249e40980a09a07200896dc5515072b`.
Candidate release SHA-256: `7b5737c67134fb2458dbc1c072c875ed5afc70521fc4115e774e3375b0c41790`.

Confirmed and fixed: automatic image/GIF payloads (explicit `render: true` now
required); generic routine file/list failures; trailing-newline log counts;
unsupported search formats advertised as available; missing per-format failure
counts; update schema format/mode constraints and empty patches; and missing
machine-readable deletion recovery receipts. Recovery remains manual, without
new `.trash/` authority. Multi-file transactions remain absent and are now explicit
in the public contract; implementing rollback/journaling without measured need was
not justified by the report's feature suggestion.

Strict test-first receipts under Xcode `ActionArtifacts/default`:

- Image/log RED: `RunSomeTests/B0C3D6EF-37C7-4AEA-9792-99F7FE511CAC.txt`.
  The initial image-size control used a below-limit fixture; after correcting that
  fixture, the unchanged image safety guards passed before implementation in
  `RunSomeTests/3FF44ED4-67DC-40E7-B645-567FC3188931.txt`. This fixture mistake
  and an initial test compile error are not counted as behavioral RED.
- Image/log GREEN and routine-error 10-case RED:
  `RunSomeTests/4F0FDDA1-E4DF-47EB-A014-835E8A0D99A0.txt`.
- Routine-error GREEN; search six-case, update-schema two-case and receipt one-case RED:
  `RunSomeTests/4F65AAC2-AB82-4402-9BA6-9026ACFB9319.txt`.
- All 52 focused/adjacent cases GREEN:
  `RunSomeTests/DE8971EE-9504-47C6-9B8C-246994F6D7FD.txt`.
- Raw SDK/transport isolation control passed without a replay-specific production fix:
  `RunSomeTests/A4E8AF45-0CBE-480C-9FB1-4288710F6BFB.txt`.
  Eight following responses contained their own text only. Client redisplay of
  already-returned images was not reproduced or certified fixed.

Final full plan: **672/672 passed, zero skips**,
`RunAllTests/4C0BBFC5-E668-4488-8F49-B221A0D621B7.txt`.
The preceding full run had five stale expected-contract failures (updated to the
deliberate new contract) and one existing timing-sensitive search failure.
The unchanged timing test measured ratios 1.356 (full), 1.027 (isolated), and 1.104
(next full run), against the unchanged 1.15 bound. Its fixed-order single pair is
a noisy oracle, not proof that every match was sorted. Both full-suite all-match
times were about 920 ms; denominator variation mostly changed the verdict. No
production performance regression was demonstrated and no threshold was relaxed.
Initial full receipt: `RunAllTests/5EA87AFA-FC3C-42CC-A07D-45458D317871.txt`;
isolated receipt: `RunSomeTests/FE65EAC1-8B06-442D-A0F0-B6FCB4175993.txt`.

Xcode test-target build passed and the issue navigator is empty. Release build
`swift build -c release --force-resolved-versions` passed in 19.90 seconds with
no warnings emitted. All existing dependency pins are unchanged.

### Measured image read deltas

Thirty alternating pairs per group, generated 512×384 PNG and 20-frame/2-second GIF,
480 successful calls (240 media, 240 following text). Two long-lived read-only
processes exited cleanly without signals; all exact owned fixture/support folders
were removed. Inspection versus legacy default intentionally changes behavior;
equivalent visual rendering is measured separately.

| Read mode | p50 before → after (ms) | p95 before → after (ms) | Response bytes before → after |
|---|---:|---:|---:|
| PNG legacy default → inspection | 4.777 → 1.852 | 5.215 → 2.426 | 377660–377662 → 494–496 |
| GIF legacy default → inspection | 57.357 → 1.531 | 59.003 → 1.938 | 37885–37887 → 510–512 |
| PNG equivalent rendering | 4.366 → 4.175 | 4.693 → 4.541 | unchanged |
| GIF equivalent rendering | 58.125 → 57.175 | 59.436 → 58.411 | unchanged |

The predeclared equivalent-render gate is p95 ≤ max(1.2×baseline p95, baseline
p95+5 ms), with candidate p95 ≤500 ms and each media call ≤1000 ms. All pass.
Inspection returns zero images and a smaller payload on every sample. Rendered
PNG pixels and ordered GIF sample colors were fully decoded and checked; retained
image SHA/size signatures match across binaries on every rendering sample.
No image blocks appeared in any of the 240 subsequent text responses.

Artifact: `/private/tmp/second-brain-acceptance.eaClR8/media-paired/media-read.json`.
Report SHA-256: `763f3b43d427646e897ae398c1a957d582fd46c10ab1a4a56f8c28ecd7529f27`.
An independent audit recomputed row completeness, hashes, timing, gates, exits and
cleanup. The harness itself has ten passing regression methods after intended
RED cases for broken image decoding, wrong/repeated frames, missing/duplicate
rows, failed cleanup, invalid timings and false performance passes.

Builds/tests were not run during the campaign. Pre-run load was 4.35/4.60/4.02;
OS activity, filesystem caches and thermals were not controlled. These are wire
and server timings, not measured model-token or billing savings.

### Remaining qualification

The expanded real JSON Schema matrix and refreshed all-tool/native harness runs
have not run for this candidate: the documented `jsonschema==4.23.0` validator
is absent, and installing it in a disposable environment awaits explicit user
approval. The Swift schema/contract tests pass but do not replace full draft
validation. Prior campaigns below describe earlier binaries, not this candidate.
Actual work-client and second-client reruns remain required, especially image
redisplay and how each client presents conditional update schemas.

## Earlier work-client feedback follow-up (2026-08-27)

The work-client report describes fast parallel calls without crashes. This is
encouraging field feedback, not a controlled latency/token comparison or completion
of the client qualification protocol. The follow-up starts at source revision
`5323f7b`; it covers media diagnostics, agent recovery guidance, and SDK string fidelity.

The reported invalid-source, Canvas-root, path-prefix, and metadata-selector
failures now provide bounded corrective guidance. Tool descriptions explain
external image/video sources, incomplete-search recovery, and link target versus
display-alias identity. Source/path policy and metadata/content separation remain
strict. Unknown framework errors remain opaque; audited media errors expose only
fixed guidance and numeric limits.

Strict TDD receipts (under Xcode's `ActionArtifacts/default` directory):

- Source diagnostics: three intended behavioral failures in
  `RunSomeTests/82A790CF-E1F3-49D4-AE9B-2700CACE1D47.txt`.
- Contract/metadata guidance: six intended failures in
  `RunSomeTests/CDF5A343-831E-49ED-9434-A9326E8B19A7.txt`.
- Media diagnostics: eight intended failures in
  `RunSomeTests/62F95F49-13AF-49B1-89AD-E799ADA1F43D.txt`.
  Valid external PNG and MOV-to-GIF controls already passed through the real
  tool, persistence, exact revision, and Git snapshot boundaries.
- After fixes, all 64 focused cases pass:
  `RunSomeTests/CC7EB6ED-8257-4D3E-90FA-51F66996EEB4.txt`.
- Before the SDK fix, the full suite was **628/630 passing, two failing, none skipped**:
  `RunAllTests/61FCB5D3-4D45-478C-BA97-8A4EC23A2E7D.txt`.

**Resolved: SDK JSON-string fidelity.** The original SDK inferred a binary value
from data-URI-looking JSON strings. Our raw-pipe regressions observed a 29-byte
literal `data:text/plain,Hello%20World` returned as 39 bytes, and rejected creation
of a log containing that valid string. A third raw test reproduced the same loss
inside nested JSON; explicit binary/image output already passed. That RED receipt is
`RunSomeTests/21C0AC1A-AEAE-45E9-BE27-6479EDCC376A.txt`.

With explicit user approval, `Vendor/swift-sdk` retains the exact 0.12.1 runtime
source at `a0ae212ebf6eab5f754c3129608bc5557637e605` and its license, changing JSON
string decoding to preserve strings. A separate explicit strong-capture annotation
removes a Swift 6.4 warning without changing ownership. All seven remote dependency
pins remain unchanged; the SDK itself is now repository-pinned. Independent audits
confirmed those are the only runtime-source differences. The vendor provenance
record and Package.swift comment specify removal after an audited official fix
passes the regression and full suites. No generated checkout was modified.

All 27 focused transport/source cases passed after the fix:
`RunSomeTests/8DD616E7-8D7B-42D6-8DC4-5564087D3AD0.txt`.
The portable SDK-only regression file uses public MCP APIs and no app fixture.
Temporarily restoring the original decoder produced four intended failures with
both ordinary-text and explicit-binary controls passing:
`RunSomeTests/D1DE77DB-0D36-466B-B05C-E33EA75B03CA.txt`.
Restoring the patch returns all six cases to green. No regression was disabled.

Final correctness verification: **638/638 Xcode tests pass, none skipped**:
`RunAllTests/7C09D08C-42D5-4177-A575-7FF3896F5271.txt`.
The Xcode build including test targets passes:
`BuildProject/BuildProject-Log-20260827-120813.txt`.
The current PDF-admission tests pass; the issue navigator may retain retired
parameterized failure identifiers from earlier runs. The new test files are visible
in Xcode. Application/patch whitespace checks pass; the initial vendor import
retains two upstream blank-at-EOF warnings documented in its provenance record.
Both files were compared byte-for-byte with upstream. The release build also passes
with `swift build -c release --force-resolved-versions`, with no warnings emitted.

### Final feedback-candidate screen

Runtime/test source revision: `569c75a` (following media fix `89460e9` and
agent-guidance fix `24a5157`); the documentation-only commit follows this source.
The final release binary SHA-256 is
`9e4ef65778cb6944449eee1d22b94aad9249e40980a09a07200896dc5515072b`.
The comparator is the previously committed CPU-selection candidate
`12ae8a0afbb7b74533f147e32ba197b3f67160c21f9e90159ba2aa40c36086fe`,
not the original `3b17eb9` baseline or the public v0.7.1 release.

Thirty alternating pairs used the unchanged `tool_workflow.py` harness with
1 MiB JSON mutations and two Markdown graph notes. Independent review verified
the complete 60-sample grid, both binary hashes, 780 recorded calls (690 successful
and 90 expected refusals), 120 clean process exits, and removal of all 180 exact
owned vault/support paths. All ten paired categories and candidate extras pass
the existing relative and absolute latency limits.

| Tool | p50 before → after (ms) | p95 before → after (ms) | p95 delta |
|---|---:|---:|---:|
| create_file | 410.869 → 410.550 | 429.213 → 418.171 | −2.57% |
| read_file | 2.247 → 1.973 | 2.620 → 2.106 | −19.64% |
| update_file | 424.645 → 422.285 | 439.090 → 430.984 | −1.85% |
| list_files | 4.776 → 4.357 | 5.274 → 4.883 | −7.43% |
| search_vault | 22.671 → 22.331 | 23.951 → 22.955 | −4.16% |
| query_links | 2.143 → 1.556 | 2.445 → 2.045 | −16.36% |
| move_path | 394.659 → 396.419 | 413.795 → 403.098 | −2.58% |
| delete_file | 40.801 → 40.516 | 46.205 → 48.142 | +4.19% |

Delete's p95 remains below its 55.447 ms relative ceiling. Every candidate main-tool
p95 is below 500 ms; the maximum individual main-tool sample is 432.467 ms.
These are observed workflow differences, not isolated SDK-patch causality or
client/model token savings. Builds and test runs were serialized with measurements;
background OS load, thermals, and filesystem cache were not controlled. A post-run
load sample was 2.87/3.28/3.09, not a pre-run baseline.

The same final binary passes seven schema cases and all nine native pilot cases
(ordinary PDF/PNG, 32/256/512 MiB metadata, 256 MiB search, compressed text,
admission queuing, active cancellation, and disconnect). The native report has
`complete_and_correct=true` and no failed case. This is one sample per native
case, not a fresh 270-case native qualification or endurance campaign.

Raw artifacts are under `/private/tmp/second-brain-sdk-fidelity.0c6WlF`:
`tool-comparison/sdk-fidelity-comparison.json`,
`schema/sdk-fidelity-schema.json`, and `native-pilot/native-workflow.json`.
The paired raw report SHA-256 is
`d92bfc66720032bc2a155eb1a717f570458a3d6342bac3dabf17ae13ee31197f`.
The pinned dependency graph audit confirms seven unchanged remote versions.
An initialized read-only process using an empty temporary vault showed no sockets
in a single `lsof` observation and exited cleanly; this is not continuous network
monitoring. The Xcode issue navigator is clear after the final regression runs.

All known scoped review findings are resolved and this candidate is ready for the
[focused work-client retest](CLIENT-EVALUATION.md#focused-retest-of-the-work-agent-feedback-fixes).
Actual client/model behavior and token cost remain unqualified. Historical large
resource/native measurements below retain their original binary attribution and
must not be presented as full release qualification of this newer binary.

## Reproducibility

- Date: 2026-08-27; arm64 Mac, 36 GiB memory, macOS 27 (26A5421a), Swift 6.4.
- Original campaign starting revision: `3b17eb9`; its then-uncommitted v2 changes
  were subsequently committed in the series ending at `5323f7b`.
- Baseline binary SHA-256:
  `fbf278625166ab9073465849eb08f0d33ba6e55995e69e0fdf229c62aff807b2`.
- Readiness candidate SHA-256:
  `ba33bedef24b3eab25d45b9ee558e175f2a0597ef934c5fb1367c8c05cbcd2be`.
- Measured native-cancellation/package-discovery candidate SHA-256:
  `da6839d6e61fc238498ecb27d1199a569a172dfd198aff6eafa9f24074079a21`.
  All five final non-native performance campaigns passed; native qualification was
  still open for this earlier candidate. Final CPU qualification is recorded below.
- Subsequent guidance-only release build SHA-256:
  `454f0e3088e5fa9c34cd7088bc3afb497a7504b6fbae6ca8f29b5a0cc3edecb7`.
  The only source changes from the archived measured implementation are one
  search-description sentence and its regression assertion. All 587 tests,
  Xcode/release builds, seven schema cases and one all-tool smoke workflow passed.
  The large performance distributions were not rerun on this later hash; all
  timing tables below remain explicitly attributed to the measured binary.
- Resumed async-native candidate SHA-256:
  `718b4462b1cc97a15e769d6baa8f22d947cf1a59665e1087f8c288933fd397f5`.
  It replaces synchronous OCR with an owned native await and invalidates legacy
  derived text through cache generation 3. The 594-test suite and nine-case native
  pilot passed, but its full native run failed on a disconnect SIGSEGV. It is not
  an accepted candidate; both successes and failure are recorded separately below.
- Last measured CPU-selection candidate SHA-256:
  `12ae8a0afbb7b74533f147e32ba197b3f67160c21f9e90159ba2aa40c36086fe`.
  It passes the 600-test suite, full 270-case native grid, original 30-cycle and
  additional 300-cycle endurance screens, and completed 64-page OCR pilot.
  Final same-binary whole-tool/schema/lifecycle checks are recorded below.
- Team builds, tests and benchmark campaigns are serialized. Background OS work,
  page cache and thermals are uncontrolled; high host load and all outliers are
  retained. These are local observations, not universal latency guarantees.
- Actual newline-delimited MCP requests validate schemas, exact results, revisions,
  Git state, recoverable deletion, readonly behavior and clean process exit.
  Timings exclude client JSON/schema decoding and independent Git checks.
- Acceptance thresholds were fixed before the measured candidate runs. Failed
  candidates remain evidence; a rejection is not counted as a faster successful call.
- Wire bytes are not model tokens or billing. See [client evaluation](CLIENT-EVALUATION.md).

The durable entry points and test-only Python environment are documented in
[README](README.md); the unchanged acceptance specifications are consolidated in
[release gates](RELEASE-GATES.md). Raw campaign artifacts and original frozen gates
are retained locally under `/private/tmp/second-brain-gate0.4g8P6R`. A durable
private archive was also created beside the repository as
`second-brain-mcp-evidence-20260827-da6839`: 407 verified entries, including a
complete measured-source snapshot, raw records, manifests, gates and receipts.
Its `evidence.tar` SHA-256 is
`a4812e53e5d0fc19bb291c9ad6060cdcf3a4ace5efa28af8f4a245c623cd45c3`;
`CHECKSUMS.sha256` independently verified the archive and manifest. This is a
post-build source snapshot, not historical cryptographic attestation. Historical
runners are audit material, not a newly maintained portable benchmark suite.
Work-client/platform qualification is still required before publication. Source commits
and newer verification are identified in the follow-up above. Evidence is not part of
the distributed server.

## Automated correctness

The source after native-cancellation, package-discovery and search-busy fixes
passed all 587 Xcode tests with no skipped tests and an Xcode build with zero
compiler warnings/errors. The full-suite artifact is
`RunAllTests/B406ED1D-9500-4923-A3A9-09E4BC1B1FA3.txt`.
The earlier readiness binary passed all 579 tests and a release build; its
measurements below must not be silently attributed to the later source.

The final guidance clarification first failed its public description assertion
(`RunSomeTests/85510CC2-9E11-4892-82CB-E0225ABCC6A4.txt`), then passed all seven
search-contract tests after adding the OCR warning. The subsequent full suite
again passed 587/587 (`RunAllTests/382867D4-F8FE-46F3-BF3A-B6BDD21E872E.txt`),
with a clean Xcode build and release build. This regression protects advertised
guidance; it does not claim to test model understanding or improve OCR accuracy.
A checksum comparison with the archived source found only the description file
and that test assertion changed; direct diffs confirmed no runtime implementation
change. Final schema/smoke artifacts are `final-guidance-schema` and
`final-guidance-pilot` under the campaign directory.

Behavior-changing fixes used focused failing tests before implementation. Key
observed failures include:

| Boundary | Observed failure before the fix | Retained regression |
|---|---|---|
| Stdio framing | Concurrent large responses interleaved; input drained without consumer demand. | Complete serialized frames, demand-driven reads, bounded frames/queues, partial-write cancellation and EOF. |
| Idle stdio | Eight repeated blocked-I/O attempts during a 100 ms idle interval. | One readiness wait; cancellation races and descriptor reuse after disconnect. |
| PDF admission | Queued direct reads retained 21,888 snapshot bytes; search retained 10,944 bytes before admission. | Same-reader admission before materialization, cancellation and cross-process permit ordering. |
| Error recovery | PDF/capacity failures became opaque internal errors; a POSIX error could expose private diagnostic text. PDF search queue exhaustion also hid its retry guidance. | Audited actionable categories and opaque unknown errors; 11 error regressions pass. |
| Native OCR cancellation | Active native cancel count stayed zero; cancellation during request setup still performed recognition once. | Real Vision request cancellation is forwarded, cancelled setup performs no recognition, and the permit stays held until native work unwinds. |
| Search scale | Large text corpora failed; corpus retention and long read leases hindered concurrent writers. | Bounded immutable captures, work accounting, deterministic paging and exact source freshness. |
| Discovery contracts | Contradictory coverage and incomplete locator pairs passed advertised schemas. | Full schema validation, truthful incomplete coverage and whole identifiers. |
| Persistence | Raced filesystem targets could escape the validated operation boundary; deletion removed unrelated parent state. | Descriptor-anchored persistence, no-clobber destinations and recoverable file-only deletion. |
| Package discovery | Four tests showed whole-area search/list/resolve/backlinks entering package contents despite explicit scope rejection. | Consistent package exclusion while preserving direct named-file reads; all four regressions plus 27 adjacent tests pass. |

Independent final structure checks found all 70 intentional untracked files in
Xcode and resolved all 14 local documentation links/anchors. No new diagnostics
or orphaned references were found. The issue navigator still displays two retired
parameterized PDF-admission test IDs; their current separate content/metadata
replacements passed in the 587-test artifact. Generated Xcode caches were not
altered to hide those historical entries.

Five additional readiness lifecycle tests are preservation/acceptance tests, not
claimed as new behavioral reds. Compiler errors, fixture mistakes, sandbox failures
and undiscovered test selections were not counted as red phases.

## Bounded response/call evidence

A public JSON/controller integration fixture places a 33-byte target field after
140,000 unrelated Canvas bytes. Both routes use the same default 64 KiB window;
search is common and excluded from this retrieval comparison.

| Retrieval route | read_file calls | Returned text bytes | Encoded CallTool.Result bytes |
|---|---:|---:|---:|
| Raw JSON continuation | 3 | 140,206 | 141,908 |
| Search-selected Canvas field | 1 | 33 | 631 |

That is 66.67% fewer retrieval calls and 99.555% fewer encoded result bytes for
this fixture. It is not a stdio latency or tokenizer/billing measurement, and
full-document validation still occurs. Four behavioral reds preceded the change;
the focused/adjacent suite passed 50 tests. See `CANVAS-READ-EVIDENCE.md` in
the campaign directory.

Metadata correctness sometimes costs a few bytes: one duplicate-link fixture
grew from 698 to 780 encoded bytes because the old result omitted a valid late
target. A long-identifier fixture shrank from 6,860 to 2,878 bytes while explicitly
reporting omissions instead of fabricating clipped identifiers. Smaller output
is not accepted at the expense of completeness or usable identifiers.

## Performance gate status

The previous candidate
`28aa060a164dac37e446ff5eef489593b0693a287a77c30d2e8026c81ce73d4a`
passed all 60 end-to-end correctness samples but failed the outgoing-link latency
gate: p95 increased from 9.533 to 17.085 ms against a 14.533 ms ceiling.
That failure is preserved. A separate 360-process / 1,440-call phase diagnostic
found a shared approximately 14 ms idle-polling cost in both the old SDK and the
replacement transport. It did not substitute for the failed gate.

### Final da6839 candidate: all eight tools passed

The unchanged all-tool gates passed: 30 alternating baseline/candidate pairs,
60 exact workflow samples, 780 verified calls and 120 clean server exits.
Schema validation passed all seven cases; a separate one-pair pilot also passed.
The 780 calls comprise 480 primary tool calls, 120 readonly checks and 180
candidate-specific contract checks. No termination or cleanup errors occurred.

| Tool | Baseline p95 (ms) | Candidate p95 (ms) | Change |
|---|---:|---:|---:|
| create_file | 780.907 | 410.087 | −47.49% |
| read_file | 15.536 | 2.123 | −86.33% |
| update_file | 434.462 | 420.552 | −3.20% |
| delete_file | 49.707 | 38.877 | −21.79% |
| list_files | 15.233 | 4.608 | −69.75% |
| search_vault | 34.874 | 23.690 | −32.07% |
| query_links | 9.491 | 1.993 | −79.00% |
| move_path | 407.894 | 395.676 | −3.00% |

These are small-workflow fixtures, including exact 1 MiB JSON mutations; they
are not the large-corpus or native-file results. Candidate changes are cumulative,
so the table does not attribute every difference to transport readiness.
The small update/move deltas should not be interpreted as a robust speedup.
The largest candidate call was 423.289 ms. Host load and all observations were
retained; there were no concurrent team builds or measurements.

Evidence: `WORKFLOW-FINAL-da6839-RESULTS.md` in the campaign directory records
the exact grid, identities and raw artifact paths. The preceding `ba33bed`
candidate also passed this campaign; its separate historical measurements remain
in `WORKFLOW-READINESS-RESULTS.md` and are not attributed to the latest binary.

### Final da6839 candidate: large-text search passed

The frozen 32/64/128/256 MiB text gates passed all 240 exact, complete queries
across 120 clean server processes, with 30 first/warm pairs per size. Each source
file is 1 MiB; these results do not apply to an individual oversized document.

| Corpus | First-query p95 | Warm-query p95 | p95 ceiling |
|---|---:|---:|---:|
| 32 MiB | 959.775 ms | 956.818 ms | 1,250 ms |
| 64 MiB | 1,840.762 ms | 1,828.589 ms | 2,500 ms |
| 128 MiB | 3,582.656 ms | 3,566.035 ms | 5,000 ms |
| 256 MiB | 7,139.061 ms | 7,081.331 ms | 10,000 ms |

Warm 32/64 MiB also passed the retained final-resource no-regression gates: baseline p95
1,003.667/1,949.220 ms became 956.818/1,828.589 ms (−4.67%/−6.19%).
These historical-baseline deltas do not isolate host load or cache effects.
Every response contained the two expected locators in 385 wire bytes. Maximum
sampled process RSS was 30.109 MiB against the 192 MiB ceiling; median peak RSS
grew only 3.234 MiB from the smallest to largest corpus against the 32 MiB
growth ceiling. All expected support directories were absent after cleanup.
Evidence: `final-text-full-da6839/gate-analysis.json` and its execution receipt
in the campaign directory. The old baseline failed the 128/256 MiB workloads;
new successful support is not presented as a speedup over those failed calls.

### Final da6839 candidate: text-search writer contention passed

The raw-record analyzer validated all 240 pairs: 30 normal and 30 active-cancellation
samples for each 32/64 MiB × first/warm class. All 480 timed mutations, plus 240
bootstrap mutations, passed exact bytes/revision/Git checks. All 480 server
processes exited cleanly and the known fixture/support paths were absent after
cleanup. No sample was omitted or replaced.

| Corpus/mode | Baseline contended p95 | Candidate contended p95 | Change |
|---|---:|---:|---:|
| 32 MiB first | 312.788 ms | 95.493 ms | −69.47% |
| 32 MiB warm | 315.422 ms | 90.822 ms | −71.21% |
| 64 MiB first | 583.527 ms | 121.236 ms | −79.22% |
| 64 MiB warm | 567.368 ms | 116.641 ms | −79.44% |

All unchanged per-class p95 and individual ceilings passed. Uncontended p95 was
at most 42.815 ms; the largest contended update was 121.316 ms. These are same-design
historical-baseline comparisons, not isolation of one code change or host noise.

All 120 cancellation samples qualified while shared admission was observed and
before a response. Cancel-to-observed-nonshared maximum was 1.565 ms; successful
followup maximum was 83.571 ms. No cancelled response was observed. Followup
includes the competing writer and Git; lock transitions are sampled, not exact
internal wait times.

Evidence: `final-writer-full-da6839/gate-analysis.json`, raw `samples.jsonl`
and `campaign-exit-receipt.json`. The independent analyzer's 21 integrity controls
passed; incomplete or corrupted reports cannot inherit PASS from a filtered
summary.

The separate 128/256 MiB support campaign also passed all 240 pairs, 480 timed
mutations and 480 clean process exits, with 30 normal plus 30 active-cancellation
samples per size/mode. Bootstrap mutations, exact revisions/Git and cleanup were
verified. These are new support-envelope checks, not old-binary speedup deltas.

| Corpus | First/warm contended update p95 | p95 ceiling |
|---|---:|---:|
| 128 MiB | 174.565 / 173.873 ms | 1,500 ms |
| 256 MiB | 292.067 / 274.035 ms | 3,000 ms |

The largest contended update was 393.854 ms. Uncontended p95 was at most
42.346 ms. Across all 120 cancellation samples, observed nonshared-release
maximum was 3.058 ms and verified followup maximum 93.034 ms; all fixed gates
passed. Evidence: `final-large-writer-full-da6839/gate-analysis.json`, raw rows
and execution receipt; `FINAL-LARGE-WRITER-EVIDENCE.md` records the campaign.

### Final da6839 candidate: dense and many-file resource gates passed

All 360 processes exited cleanly: 720 exact complete queries and 120 expected
whole-request budget rejections. Each binary/fixture group contains 30 processes;
Canvas also verifies the next 50 locators without duplicates. Every Canvas p95
passed the unchanged comparative ceiling against the intermediate `fad5d0f`
capture binary. This is not a comparison against the old public release.

| Candidate fixture | First/warm p95 | Maximum process RSS |
|---|---:|---:|
| 10,000 Canvas nodes | 101.895 / 99.407 ms | 31.547 MiB |
| 100,000 Canvas nodes | 900.940 / 902.163 ms | 117.297 MiB |
| 1,000 tiny Markdown files | 343.676 / 346.344 ms | 20.547 MiB |
| 10,000 tiny Markdown files | 3,320.510 / 3,329.584 ms | 43.125 MiB |
| 1,000 long-path files | 621.688 / 613.533 ms | 26.500 MiB |
| 5,000 long-path files | Expected whole-budget rejection | 48.329 MiB |

Canvas continuation p95 was 99.473/907.227 ms for 10,000/100,000 nodes.
Maximum candidate RSS was 117.297 MiB, below 192 MiB; tiny-file median peak
growth was 21.102 MiB, below 64 MiB. No new absolute namespace latency SLO is
claimed. The rejected fixture exceeded the predeclared manifest budget; its
rejection time is not successful-search throughput.

All response and cursor bounds passed. Structured/result byte counts use compact
UTF-8 JSON re-encoding; actual wire bytes were recorded separately. Raw reanalysis
matched the saved summary, and fixture cleanup was verified. Evidence:
`final-resource-full-da6839/summary.json` and `samples.jsonl`.

### Native pilot: active cancellation gate failed

Seven native workload classes passed their one-sample correctness/resource screen:
ordinary PDF/PNG import/read/readonly restart, 32/256/512 MiB PDF metadata,
256 MiB PDF search, controlled compressed-page expansion and two-process queued
PDF admission/cancellation. These pilots are not p95 distributions.

Active OCR search cancellation failed: a subsequent ordinary PDF metadata read
took 32,454.29 ms against the frozen 5,000 ms bound. The 64-page generated
image-only source was captured and the search was still outstanding before
cancellation. All pilot children exited cleanly; no forced signals or cleanup
errors occurred. Disconnect was not reached because the harness stops on failure.

Observed peaks included 533.77 MiB for 512 MiB source metadata, 280.25 MiB
for 256 MiB PDF search and 94.95 MiB for the active-cancellation case.
These use separate native-source limits, not the small-text 192 MiB target.

Evidence: `native-pilot-ba33-authorized/native-workflow.json` in the campaign
directory. The earlier sandbox-denied startup is retained separately and is not
a product failure. At this stage the active-cancellation cause was unresolved;
subsequent diagnosis is recorded below. No successful cancellation delta is claimed.

A diagnostic repeat did not reproduce the 32-second delay: one-page OCR search
completed in 189.32 ms; cancellation of a 64-page search was followed by metadata
in 82.31 ms with no cancelled-search result. Without cancellation, 64-page search
took 6,161.04 ms while pings remained below 1 ms. This rules out a persistent
whole-loop server blockage in that run, not the original failure. This primed
repeat did not isolate the slow native call; the later unprimed probe does.

### Final da6839 candidate: graph writer contention passed

The unchanged graph-specific gates passed 30 observations per size/mode:
120 paired samples, 240 clean server processes and 360 exact-byte/revision/Git
verified mutations including bootstrap. Backlink groups and the 64 MiB cursor
continuation were correct. Raw reanalysis and owned-fixture cleanup passed.

| Markdown corpus | First-query contended update p95 | Warm-query contended update p95 | Gate |
|---|---:|---:|---:|
| 32 MiB | 157.243 ms | 158.280 ms | 400 ms |
| 64 MiB | 255.781 ms | 249.652 ms | 750 ms |

The largest contended update was 259.684 ms. Uncontended p95 was at most
40.777 ms, and the largest uncontended observation was 42.844 ms. These are
prospective graph targets, not old-binary speedup percentages. The measurements
do not justify adding graph capture/storage complexity. Evidence:
`final-graph-writer-full-da6839/summary.json` and `samples.jsonl`.

The preceding `ba33bed` candidate also passed this campaign; those separate
historical measurements remain in `GRAPH-WRITER-FULL-EVIDENCE.md` and
`readiness-graph-writer-full-ba33`, not attributed to the latest binary.

### Latest native candidate: gate still failed

The `da6839` candidate again passed the first seven native pilot classes, but
active OCR cancellation followed by metadata took 15,467.16 ms against the same
5,000 ms gate. All children exited cleanly. No full native distribution was
started, and disconnect was not reached.

The native forwarding regression is fixed, but it does not establish a fix for
this latency failure. The earlier fast diagnostic primed PDF metadata first;
the failing workload starts OCR as its first PDF operation. An unprimed probe
reproduced a 17,200.88 ms successor delay while an MCP ping completed in 0.499 ms.
A one-second stack sample of only the owned server process found Vision blocked
inside text-recognition initialization while another native task compiled and
validated a Neural Engine model. No cancelled-search result was emitted.

This localizes the sampled stall to native OCR initialization, not MCP transport
or PDFKit page extraction. It does not establish a universal framework cause or
a remedy. The completed compute-device and async-API experiments below did not
eliminate the delay; neither changed production behavior. The unpaired 32-second,
15-second and 17-second samples are not reported as percentage improvements.
Probe evidence: `native-cold-cancel-da6839/native-cold-cancel-probe.json` and
`owned-native-server-sample.txt` in the same directory.

Evidence: `native-pilot-da6839/native-workflow.json` in the campaign directory.
All five final text/writer/resource/graph campaigns passed. Native cancellation
qualification remained open at this earlier stage; the final CPU results appear below.

### Rejected OCR compute-device experiment

An isolated optimized native probe reproduced the failure with unchanged accurate
recognition and language correction. Early cancellation took 15,611.80 ms with
framework-selected devices and 16,677.71 ms with an explicitly supported CPU.
CPU device discovery took only 7.10 ms; the delay remained inside native execution.
Both fail the unchanged 5,000 ms screen. All eight child processes exited cleanly.

The same generated raster also exposed an OCR correctness limitation: both arms
returned `HELLO WORLO` instead of `HELLO WORLD` on all 130 completed pages. Those
quality checks remain failed; identical mistakes are not successful recognition.
Later cancellation (100 ms after native execution began) unwound within 10 ms in
both arms. This timing correlation motivated the task-context probe below, whose
uncancelled control also stalled. No cancellation delay or device change was made. No production compute
policy changed and no 30-sample comparison was started.

Evidence: `ocr-device-pilot-a914/ocr-device-experiment.json`; standalone probe SHA
`a914487d5677befbd6828ce7063b69325e64b2557762f4fb1ff879f1dfca670a`.
This diagnostic does not replace real-MCP qualification.

A subsequent 12-case probe preserved the real Swift task cancellation context.
Its first uncancelled one-page control spent 32,409.69 ms inside native execution,
with neither task cancellation nor a Vision cancel call. The delay therefore does
not require cancellation. Later controls completed in about 243–253 ms.
After initialization, all nine cancellation cases met their timing/active-work
checks: native forwarding unwound in 2.92–8.29 ms; task-only cancellation waited
135.58–162.64 ms for the native call to return. These are diagnostic samples, not
p95 estimates. The bridge is retained; removing it or delaying cancellation is not
supported by this evidence. The three uncancelled controls retained the same OCR
text mismatch. All 12 children exited cleanly.

Evidence: `task-cancel-pilot-7976/task-cancel-experiment.json`.

The newer async Vision API was then screened with the same revision, raster,
accurate mode, language and correction settings. A later configuration-parity test
found that its implicit minimum text height differed (0.03125 versus legacy 0),
so this historical screen does not establish complete configuration parity.
Its first uncancelled request also took 32,400.02 ms, failing
the 5,000 ms target. Subsequent 50/100 ms task cancellations returned in under 1 ms;
fresh successor calls took about 185–187 ms. A one-second post-cancellation CPU
observation is not proof that all internal native work stopped. The exact text
oracle still failed identically, all three processes exited cleanly, and neither
migration acceptance nor native quiescence is claimed. No production API change
was made. Cancellation cases ran after the uncancelled control: fresh child
processes did not reset shared native caches. Unprimed cancellation/recovery
therefore remains untested; this pilot does not rule out an improvement there.
Apple presents awaited request completion as the supported concurrency boundary,
with no separate native-drain API. Unobserved internal quiescence is a measurement
limit, not by itself a requirement to introduce a worker process. See Apple's
[Vision concurrency guidance](https://developer.apple.com/videos/play/wwdc2024/10163/).
Evidence: `modern-vision-pilot-d46d/modern-vision-experiment.json`.

One cancellation-first repeat reused the exact existing binary and harness with
only the recorded order override `cancel50 → first1 → cancel100`. Both qualified
cancellations unwound in 0.238/0.325 ms; successors took 171.895/190.872 ms. The
intervening uncancelled control took 227.967 ms. All three processes exited zero
without forced signals, all diagnostic/latency checks passed, and peak RSS was
85.156 MiB. Tail CPU was 50.678/25.835 ms; sampled post-join peak-RSS growth was
11.156/0.281 MiB, which is reported rather than treated as proof of native drainage.

The exact text oracle still failed, so the combined harness correctly exited 1.
No initialization stall was observed: this fast repeat is inconclusive for
cancellation during slow initialization and does not accept migration. Evidence:
`modern-vision-cancel-first-d46d-20260827/modern-vision-experiment.json` and its
execution receipt; the order and unchanged limits are recorded in
`MODERN-VISION-CANCEL-FIRST-REPEAT.md`. No application code changed.

This earlier default-device probe did not resolve unprimed first-use OCR latency. System and
native model caches were uncontrolled: first-use refers to the running process,
not a freshly booted OS. Neither compute-device selection nor API modernization
demonstrated a remedy. Further platform comparison is needed before considering
a larger architectural change.

### Cache and capture lifecycle: passed on da6839

The real-MCP lifecycle campaign passed its frozen correctness and resource checks.
Cold/warm/restart/corrupt-cache/full-cache fallback all returned the exact expected
page locator with complete coverage. The full cache remained at its 64 MiB logical
quota without publishing another entry. These are single lifecycle observations,
not latency distributions.

Capture storage peaked at 256 MiB logical and allocated bytes across 29 samples;
the 20 ms sampling interval is not proof of an unsampled instantaneous maximum.
Queued cancellation plus clean shutdown took 13.294 ms. After the explicitly owned
process was killed to model a crash, restart removed its stale capture and returned
the correct result in 181.277 ms after PDF admission was released.

All six child processes were reaped before cleanup: five exited zero and one had
the explicitly planned SIGKILL/-9 result. There were no unexpected termination or
cleanup errors. This does not waive the separate native OCR cancellation failure.
Evidence: `final-lifecycle-da6839/cache-capture-lifecycle.json`.

## Resumed native qualification

The work machine was reported to run macOS Tahoe (26); local measurements remain
on macOS 27 and are not Tahoe measurements. Before any new native implementation
or test warmup, the current `454f0e3` binary reproduced the active-cancellation
failure: ordinary metadata waited 15,694.506 ms, while ping completed in 0.505 ms.
The cancelled search emitted no result; its process exited zero without forced
signals or cleanup errors. The unchanged 5,000 ms check failed. An initial
sandbox-denied attempt is retained as infrastructure evidence, not a product red.
Evidence: `resume-current-cold-454-authorized/native-cold-cancel-probe.json` and
its owned-process stack sample; the sample again located native model compilation.

The `718b446` candidate directly awaits modern Vision recognition inside the existing
PDF admission boundary. The testable hypothesis is prompt cancellation/recovery,
not removal of all native initialization cost. Recognition quality/settings,
source and output bounds, and the original nine native gates remain unchanged.
The configuration-parity test caught a real default mismatch before measurement:
modern minimum text height was 0.03125 versus legacy 0. Its 36/37 focused run
failed that assertion (`RunSomeTests/5FC6AA07-27DD-4C6C-A280-EE4C0C47AF37.txt`),
preventing an unnoticed loss of small-text coverage. The candidate explicitly
preserves the legacy zero threshold.
An additional pre-candidate endurance screen requires 30 active cancellations in
one server, each followed by correct metadata within 5 seconds, no cancelled
response, clean exit within 5 seconds, the existing 256 MiB process-RSS bound,
and at most 64 MiB settled-RSS growth from the first cycle. This supplements,
not replaces, the original native grid and does not claim private native quiescence.

### Resumed implementation and pilot evidence

The behavior-preserving async interface stage passed all 30 existing focused tests.
In that same run, both legacy-cache regressions failed because valid generation-2
text was reused without fresh extraction (`RunSomeTests/5BB194D4-91FB-40F7-A3EB-60A70FD8EB0F.txt`).
Changing the derived-cache generation to 3 passed all 18 cache/extraction tests
(`RunSomeTests/56438FD6-34C2-48A5-821A-3FB31BEFC58C.txt`), including warm reuse and
safe fresh extraction without eviction when legacy entries fill the shared quota.

After correcting the text-height default, all 37 focused tests passed
(`RunSomeTests/BABC62B1-DC72-48AA-99C9-494A66B8A4D6.txt`). The eight native tests
cover inherited cancellation, permit retention through a held await, pre-cancelled
setup, late cancellation, native-error cancellation precedence, raster lifetime,
embedded-text bypass and effective configuration parity. They use injected native
performers, not real OCR warmups. The release build took 17.02 seconds.

The first new release-binary operation, before the full suite or native pilot,
passed the same cancellation probe: metadata returned in 2.899 ms (2.928 ms from
notification start), ping in 0.603 ms, no cancelled result, and a clean process exit
with no cleanup errors. Peak process RSS was 77,742,080 bytes. The pre-change
15,694.506 ms and post-change 2.899 ms observations are not a paired distribution
or an OS-cold guarantee. Evidence: `resume-modern-first-cold-718b`.

All nine native pilot cases then passed, including active cancellation (2.937 ms)
and disconnect (15.178 ms), with 12 clean child exits. Evidence:
`resume-modern-native-pilot-718b/native-workflow.json`. This pilot is not a p95 run.
The subsequent full Xcode suite passed 594/594 with no skips or expected failures
(`RunAllTests/46DF0D1E-1A14-4852-8747-FA27E063189A.txt`); the Xcode build also passed
(`BuildProject/BuildProject-Log-20260827-091648.txt`).

### Repeated disconnect failure and shutdown ownership

The full `718b446` native run stopped after 28 passing records: the fourth
active-disconnect case exited with SIGSEGV (-11), not a forced watchdog signal.
Its restart returned correct metadata/search and cleaned its stale capture; both
owned roots were removed, with no cleanup errors. Evidence:
`resume-modern-native-full-718b/native-workflow.json`. The failed candidate is
retained rather than treating its faster cancellation pilot as acceptance.

The owned-process crash report matched the release binary UUID and showed
TextRecognition/ANE compilation on a background queue while the main thread ran
process-exit global destructors. Independently, SDK inspection found that
`waitUntilCompleted()` waits only for its receive loop, not incoming handlers.
Two real setup/EOF regressions then failed on the unchanged implementation:
active work was not cancelled/joined, and already-client-cancelled work was not
joined (`RunSomeTests/4ECA0CA1-6528-4D7A-A7F5-6EC4037AB93C.txt`). An application-owned
tool-task lifecycle now closes admission, cancels and joins accepted work before
setup returns. The two regressions plus terminal-admission rejection passed
(`RunSomeTests/DEC15AE3-3A06-45A6-9B80-58F0FEBB469C.txt`). At that point mutation durability,
full-suite verification and real native remeasurement were still required; these
unit results alone do not prove the SIGSEGV is eliminated.

The subsequent shutdown candidate is
`af4675662f5f514919325c88e6fce99d37d67d069c300d291f72c764f9d30a57`.
Its real post-persistence Git snapshot test and startup/transport/native adjacency
passed 36/36 (`RunSomeTests/0D371145-861B-43DA-8271-DC4487514D70.txt`); an additional
pre-cancelled-caller/no-entry control passed
(`RunSomeTests/E4FFE35D-FE87-4D80-A2CE-73082F953CDC.txt`). The release build passed
in 16.33 seconds. Its nine native pilot cases passed with clean exits
(`resume-drained-native-pilot-af4675`). Repeated native qualification remains in
progress, and the previous failed source is preserved separately with reconstruction
provenance—not retroactive build attestation.

The repeated `af4675` native grid passed 270/270 cases, 810 recorded calls and
360 clean exits; all 540 owned directories were absent afterward. Active-cancel
recovery p95/max was 3.444/3.623 ms; disconnect p95/max was 12.667/12.816 ms.
Evidence: `resume-drained-native-full-af4675/native-workflow.json`.

However, the additive single-process endurance screen failed on its 14th active
cancellation after 13 successful recoveries (2.025–3.203 ms). The next PDF metadata
request exceeded its unchanged 5-second deadline, and shutdown required one
SIGTERM (exit -15). Peak RSS was 110,018,560 bytes, within the bound; cleanup had
no errors. Evidence: `resume-drained-endurance-af4675/native-endurance.json`.
This later failure keeps native qualification open despite the passing fresh-process
grid. The next step is sampling the stalled owned process; no timeout-abandonment,
forced-exit workaround or acceptance-threshold increase has been introduced.

A diagnostic-only repeat failed again on cycle 14. Sampling began only after the
same five-second deadline, so its additional 1,466.716 ms is not release timing.
The owned PID 9244 sample contained 13 Swift cooperative threads and 12
CoreRecognition queue threads blocked on TextRecognition locks, plus an ANE
compilation thread awaiting a synchronous XPC reply. The main thread was idle;
no app lifecycle-lock frame appeared in those blocked native stacks. The host has
14 logical CPUs. This supports native work surviving public cancellation and
saturating the cooperative pool; exact request-to-thread identity is not observed.
This diagnostic eventually exited cleanly, but its deadline failure remains.
Evidence: `resume-drained-endurance-diagnostic-af4675`, including the complete
owned-process sample. A supported-CPU selection experiment is being evaluated
without changing recognition settings or acceptance thresholds. Its request-boundary
assertion first failed (`RunSomeTests/70599816-B04A-4FF7-9787-5842A64BC63C.txt`), then
38 focused tests passed with supported CPU selection
(`RunSomeTests/C1228216-B16B-47E2-AE6B-9C17BA3861E3.txt`). Experimental release SHA-256
is `12ae8a0afbb7b74533f147e32ba197b3f67160c21f9e90159ba2aa40c36086fe`;
its build took 18.56 seconds. At that point it was an experiment, not an accepted
performance improvement; the subsequent unchanged endurance and native gates follow.

The CPU candidate passed its first unchanged 30-cycle endurance run, with
maximum recovery 3.421 ms and clean exit. Settled RSS grew from 61,227,008 to
75,972,608 bytes, within the 64 MiB growth limit. Evidence:
`resume-cpu-endurance-12ae8a/native-endurance.json`. Because growth was observable,
a separately labelled 300-cycle stress screen will retain the same 5-second,
256 MiB peak and 64 MiB settled-growth limits; it does not replace the original
30-cycle result. Completed bitmap OCR also needs direct correctness verification.

The additional 300-cycle screen passed with p95/max recovery 3.226/3.772 ms,
109,445,120-byte process peak RSS and clean exit in 14.650 ms. Maximum settled
RSS growth was 27,230,208 bytes; the final 100 cycles grew only 294,912 bytes
from their first to last observation. This is an observed near-plateau, not an
unlimited-duration memory guarantee. Binary/source/fixture identity, all original
latency and memory limits, and both owned-directory removals independently passed.
Evidence: `resume-cpu-endurance300-12ae8a/native-endurance.json` and its independent
analysis. The full suite passed 600/600 without skips
(`RunAllTests/227028F7-4B98-451F-A656-A51259364ABC.txt`); Xcode build
`BuildProject/BuildProject-Log-20260827-094604.txt` passed. A subsequent test-only
portability correction permits hosts without an advertised CPU stage; it preserves
assertions of CPU selection where supported and default selection otherwise.

The final CPU native grid passed 270/270 cases, 810 recorded calls and 360 clean
exits; all 540 owned directories were removed. Cancellation recovery p95/max was
3.527/3.554 ms and disconnect p95/max 12.652/15.113 ms. All original native
latency/RSS gates passed. Evidence: `resume-cpu-native-full-12ae8a` and its
independent analysis; these are the CPU binary's measurements, not transferred
from the earlier `af4675` candidate.

A separate completed-OCR pilot on that same binary returned exactly pages 1–64
across 50+14 results, with complete coverage. Fresh first-query latency was
9,004.607 ms; continuation 15.630 ms; cached first-query/continuation
17.297/14.932 ms. Process peak RSS was 87,719,936 bytes and clean exit took
14.267 ms. All 64 cached texts were `HELLO WORLO`, matching the previously
observed recognition error; a `WORLD` query correctly found no derived-text match.
Thus this proves complete processing/locator delivery and cache reuse, not perfect
OCR. The prior 32.4-second standalone one-page observation is a different workload
and is not used for a percentage speedup. Evidence: `resume-cpu-ocr-completion-12ae8a`.
Its four pure locator-validator controls passed before the pilot.

### Final same-binary whole-tool and lifecycle verification

The `12ae8a` binary passed 30 alternating baseline/candidate pairs: 60 workflows,
780 calls (690 successes and 90 expected errors), 120 clean exits and all frozen
latency gates. Independent checks revalidated the exact grid, binary hashes,
690 output schemas, 630 retained-input schemas and removal of 180 owned paths.
The baseline remains source `3b17eb9`, not public v0.7.1.

| Tool | Baseline p95 (ms) | Final p95 (ms) | Change |
|---|---:|---:|---:|
| create_file | 823.000 | 437.189 | −46.88% |
| read_file | 13.877 | 2.813 | −79.73% |
| update_file | 452.177 | 443.059 | −2.02% |
| delete_file | 60.816 | 49.109 | −19.25% |
| list_files | 15.861 | 6.050 | −61.86% |
| search_vault | 32.573 | 24.636 | −24.37% |
| query_links | 13.324 | 2.752 | −79.35% |
| move_path | 426.552 | 415.114 | −2.68% |

These cumulative small-workflow deltas do not isolate the CPU selection change;
update/move differences remain too small to claim a robust speedup. Evidence:
`resume-cpu-all-tools-12ae8a/final-cpu-paired.json` and its independent analysis.
All seven final schema cases passed (`resume-cpu-schema-12ae8a`).

The final cache/capture lifecycle scenario also passed: cold/warm/restarted/corrupt/
full-cache correctness, exact 64 MiB cache quota, bounded 256 MiB captures, queued
cancellation/exit in 12.904 ms, and recovery in 193.070 ms after releasing the
held permit. All six children were reaped: five clean exits and the one explicit
owned SIGKILL/-9 crash injection; no unexpected shutdown or cleanup failures.
Evidence: `resume-cpu-lifecycle-12ae8a/cache-capture-lifecycle.json`.

After the test-only portability and unused-result corrections, the final Xcode
suite again passed 600/600 with zero skips, expected failures or tests not run
(`RunAllTests/3BA20A55-F8D8-4E43-A1DD-694CE2E62E7A.txt`), and the final Xcode build
passed (`BuildProject/BuildProject-Log-20260827-095627.txt`). The issue navigator
still retains the two retired parameterized PDF-admission IDs described above;
there are no current compiler warnings/errors. All 61 untracked Swift files are
intentional and visible in Xcode; no missing or orphaned Swift references were found.

## Remaining release checks

- Commit the reviewed source and complete client qualification before publication.
  The five large non-native campaigns passed on `da6839`; native qualification,
  both endurance screens and final whole-tool checks passed locally on `12ae8a`.
  These are not Tahoe results.
- Validate the clarified agent-visible OCR guidance in the separate client
  evaluation; complete processing must not imply perfect recognition.
- Final independent source/documentation review if any gate requires another fix.
- Work-client and second-client evaluation with actual model behavior. Server
  benchmarks cannot certify absence of model retry loops or a billing reduction.

Transport bounds do not cap all decoded SDK request tasks. Text/Canvas memory
results do not certify large PDF source retention or arbitrary native decoding.
No guarantee is made that every model, vault or media file fits these workloads.
