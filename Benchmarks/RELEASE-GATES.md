# Frozen v2 release gates

This consolidates the acceptance criteria fixed before the candidate campaigns
on 2026-08-27. It does not change thresholds or certify a release. Results and
binary identities belong in [V2-VALIDATION.md](V2-VALIDATION.md); runnable durable
entry points belong in [README.md](README.md).

## Common rules

- Use generated disposable vaults, exact fixture manifests and hashed binaries.
  Never measure or clean user vaults. Reap every owned child before cleanup;
  unknown replacement identities retain the fixture and fail the run.
- Keep every sample, outlier, error and exit status. A missing/duplicate sample,
  incorrect result, timeout, unplanned signal or cleanup error fails the campaign.
  Analyze raw records, not a summary that filters unsuccessful observations.
- Serialize team builds, tests and measurements. Record OS/background load.
  First/warm refers to application process/derived state, not cold OS caches.
- Distribution groups contain 30 observations; nearest-rank p95 is sorted
  observation `ceil(0.95 * n)`. Pilots screen individual limits, not distributions.
- RPC latency runs from request write-start through complete-frame arrival.
  Exclude request serialization, client JSON/schema decoding and independent
  Git checks. Mutation latency includes required Git snapshot completion.
- Process peak RSS comes from Darwin `wait4`; sampled RSS/disk/lock observations
  are not continuous peaks or exact internal wait times. MiB means 1,048,576 bytes.
- Success requires exact locators/coverage, bytes/revisions and applicable Git
  state. A newly supported workload is availability, not a speedup over failure.
  Wire bytes are not model tokens, billing or proof that a model avoids loops.

## Eight-tool workflow

Use the durable `tool_workflow.py` and `schema_contract.py`: exact 1 MiB JSON
mutations, two Markdown graph notes, writable/readonly processes and candidate
contract cases. Run 30 alternating baseline/candidate pairs. Validate advertised
schemas, readonly nonmutation, recoverable trash and every expected response.

For each comparable main-tool and readonly category, candidate p95 must be at
most `max(1.20 * baseline_p95, baseline_p95 + 5 ms)`, also at most 500 ms.
Every candidate observation must be at most 1,000 ms. Candidate-only calls retain
the absolute limits without a baseline ratio. Baseline source is `3b17eb9`,
not the older public v0.7.1 release.

## Sparse text search

Exact 32/64/128/256 MiB corpora of 1 MiB Markdown sources; two marker paths.
Thirty fresh processes per size, each issuing first and same-process warm searches.
Require both exact locators, complete coverage, no cursor and at most 512
JSON-RPC wire bytes. Every process peak RSS must be at most 192 MiB; median peak
growth from 32 to 256 MiB must be at most 32 MiB.

| Corpus | First/warm p95 ceiling |
|---|---:|
| 32 MiB | 1,250 ms |
| 64 MiB | 2,500 ms |
| 128 MiB | 5,000 ms |
| 256 MiB | 10,000 ms |

The additional final-resource screen retains a no-regression cap: warm 32/64 MiB
must not exceed the measured baseline warm p95
(1,003.667208/1,949.219583 ms respectively).
The old baseline did not successfully support 128/256 MiB.

## Search/writer contention

Two real MCP processes share one exact-size Markdown vault and fixed-length
control note. Complete bootstrap recovery outside timing. Observe the actual
Darwin shared OFD lock before submitting the competing mutation; normal search
and mutation intervals must overlap. First/warm modes use deterministic paired
ordering (seed 260826); warm adds a verified untimed search. Each size/mode
requires 30 normal plus 30 qualified active-cancellation pairs. The same per-size
fixture and growing Git history are reused across samples; only processes and
derived support state are fresh.

| Corpus/mode | Uncontended p95 ceiling (ms) | Contended p95 ceiling (ms) | Contended individual maximum (ms) |
|---|---:|---:|---:|
| 32 MiB first | 63.29745 | 375.3459504 | 750 |
| 32 MiB warm | 69.9146004 | 378.5061504 | 750 |
| 64 MiB first | 73.21515 | 700.23285 | 1,500 |
| 64 MiB warm | 68.7612492 | 680.8413 | 1,500 |
| 128 MiB first/warm | 100 | 1,500 | 3,000 |
| 256 MiB first/warm | 100 | 3,000 | 6,000 |

Every uncontended observation must be at most 250 ms, including cancellation
controls. Small-corpus contended ceilings are
`min(baseline_p95 * 1.20, 400/750 ms)`; uncontended ceilings are
`min(100, max(baseline_p95 * 1.20, baseline_p95 + 10 ms))`.
Larger sizes are prospective support targets, not baseline deltas.

Cancellation must be sent while the shared lock is observed and before the search
response arrives. For every size/mode, cancel-to-observed-nonshared p95/maximum
must be at most 100/250 ms; cancel-to-successful-followup at most 500/1,000 ms.
The followup includes the writer/Git. A cancellation notification has no
acknowledgement: later success/error/no-response is recorded, not used to infer
the exact server cancellation instant. Verify each mutation's exact bytes,
revision and Git HEAD, and the followup's current revision.

Raw analysis requires the complete size/mode/cancellation/sample-index grid.
Frozen harness field `query_cpu_ms` measures wall time inside lock probes,
not CPU. Final harness exit and fixture/support cleanup require a separate
execution receipt; completed rows alone cannot prove them.

## Dense Canvas and namespace resources

- Canvas: one valid document with 10,000 or 100,000 distinct short-ID text nodes,
  one matching field each, within 10 MiB. Thirty alternating-order processes per
  candidate/comparator and fixture, each with first/warm/continuation calls.
  Require canonical first 50 then next 50 exact locators, complete coverage,
  no duplicates and a usable bounded cursor.
- Canvas p95 per mode must be at most `comparator_p95 * 1.20 + 20 ms`.
  Comparator is the preserved capture candidate with SHA beginning `fad5d0f`,
  not the original baseline; differences are cumulative, not one-change causality.
- Every process peak must be at most 192 MiB. Search structured output is at most
  256 KiB, encoded CallTool.Result at most 768 KiB, cursor at most 1,024 bytes.
  Structured/result sizes use portable compact UTF-8 JSON re-encoding; record
  actual received JSON-RPC wire bytes separately.
- Namespace fixtures: 1,000/10,000 tiny Markdown files and 1,000/5,000 long-path
  files. Predict the fixed 8 MiB manifest eligibility before execution; canonical
  and temporary-path aliases must classify identically. Eligible fixtures return
  both exact marker paths with complete coverage. Over-budget candidates must
  reject the entire request, never succeed partially. Comparator rejection and
  success are reported separately; rejection speed is not successful throughput.
- Every namespace process peak must be at most 192 MiB; median tiny-file peak
  growth from 1,000 to 10,000 files at most 64 MiB. No absolute namespace latency
  SLO was introduced.

## Graph/writer contention

Exact 32/64 MiB Markdown corpora, sources at most 1 MiB, two wiki occurrences per
numbered source resolving to a real Target.md included in the total. A separate
JSON control file is outside that Markdown total. Two real processes, observed
shared OFD admission, verified bootstrap and deterministic paired mutations.
Thirty first/warm observations per size; warm adds an untimed graph query. The
same per-size fixture and growing Git history are reused across samples; fresh
processes/support do not mean a fresh Git repository.

Contended mutation p95 is at most 400/750 ms and individual maximum 750/1,500 ms
for 32/64 MiB. Uncontended p95/maximum is 100/250 ms. Require exact source groups,
count two, resolved Markdown format, no ambiguity and complete coverage. The
64 MiB continuation after the concurrent JSON mutation returns the remaining
14 groups after the initial 50. Verify bytes, revision and Git for every mutation.
These are prospective graph targets, not old-binary speedup claims.

## Native PDF/image screen

Use durable `native_workflow.py` and `native_fixtures.py`. Start with one sample;
only passing screens proceed to 30 independent samples per class. Generated
fixtures: three known Helvetica pages with title/author; 32×24 RGB PNG; valid
32/256/512 MiB padded PDFs; 256 KiB compressed text page; 64 image-only OCR pages.
Padding tests source retention, not decompression. Preserve raster/text manifests.

| Workload | Per-process RSS ceiling | Individual RPC ceiling |
|---|---:|---:|
| Ordinary PDF/PNG | 256 MiB | 5 s |
| 32/256/512 MiB metadata | 320/768/1,280 MiB | 1.5/6/12 s |
| 256 MiB PDF search | 768 MiB | 12 s |
| Controlled compressed page | 256 MiB | 12 s |

Queued two-process combined RSS growth is at most 64 MiB; recovery is at most
2 s after releasing the deliberately held PDF permit. After active OCR search
cancellation, ordinary metadata must complete within 5 s and the cancelled ID
must remain silent. Outstanding-search disconnect must exit cleanly within 5 s,
without forced termination, and restart must read normally. Qualification
requires an observed complete capture and outstanding request, not a completed
search. Use the 45 s RPC watchdog and 20 ms live RSS guard. These checks do not
guarantee OCR exactness or arbitrary native decoding/cancellation behavior.

## Cache/capture lifecycle

This is a correctness/resource scenario, not a 30-sample distribution.

- Exact page-one locator and complete coverage for generated three-page PDF
  cold/warm/restart/corrupt-cache/full-cache fallback, each within 5 s.
  Warm/restart must not rewrite the generation. Fill exactly 64 MiB of cache
  regular-file payload; fallback adds no final bytes/entries. Total cache payload
  is at most 64 MiB and recursive entries at most 1,024.
- Hold the owned PDF permit while two search processes share one exact 256 MiB
  source capture. Sample active spool at most 256 MiB logical, 320 MiB allocated,
  10,000 files. Cancel queued process and require clean exit within 2 s; existing
  capture must remain unchanged.
- After observing full capture, SIGKILL only that known first child, reap its
  expected -9 result, then insert a valid zero-byte sentinel into its abandoned
  spool. Restart must remove the sentinel before completing replacement capture.
  After releasing PDF admission, exact complete search must finish within 12 s.
  No active capture may remain afterward, before fixture cleanup.
- Record the single intentional crash separately; every other child exits zero.
  Reap all before owned cleanup. Use 20 ms disk samples, bounded close watchdogs,
  no-follow identity checks and final state evidence. No unsampled peak claim.

## Publication evidence

Keep final raw rows, fixture manifests, runner/gate hashes, exit/cleanup receipts
and relevant failed-gate summaries in a durable checksummed evidence bundle.
Record the final source commit before publication. Temporary diagnostic paths
alone are not a reproducible release archive. Do not publish user data or include
large generated vaults/binaries merely to preserve measurements.

The separate [client check](CLIENT-EVALUATION.md) remains required. Server tests
do not certify client discovery, model choices, retry behavior or token savings.
