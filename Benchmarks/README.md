# Real-stdio validation

These macOS/Python 3.9+ harnesses exercise a supplied release binary, not user vaults.
They create disposable vaults, verify exact revisions/Git/trash, and validate the
complete advertised JSON Schemas. Temporary vaults and their initially absent
Application Support hash directories are normally removed after their owned processes
exit. Unconfirmed child exit or unsafe cleanup retains the fixture and fails the run.
Evidence remains in a fresh directory printed at startup (`--output` selects a new
directory; existing directories are never reused).

Install the test-only validator in a disposable Python environment:

```sh
python3 -m venv /absolute/path/to/disposable-validation-env
/absolute/path/to/disposable-validation-env/bin/python -m pip install jsonschema==4.23.0
```

The server's Swift dependencies and runtime do not depend on this validator. The
installed validator version is recorded in each report. Optimized Python (`-O` or
`PYTHONOPTIMIZE`) is rejected because it would disable verification assertions.

Run the isolated harness regressions without launching the MCP:

```sh
python -B -m unittest discover -s Benchmarks -p test_reliability.py -v
```

```sh
python Benchmarks/tool_workflow.py --binary /absolute/path/to/second-brain-mcp \
  --sha BINARY_SHA256 --label candidate --samples 30 --candidate-contracts
python Benchmarks/schema_contract.py --binary /absolute/path/to/second-brain-mcp \
  --sha BINARY_SHA256 --label schema
```

Use that environment's Python. Obtain the binary hash with `shasum -a 256`.
For an alternating paired comparison, add `--comparison-binary` and
`--comparison-sha` to the workflow command. Primary is the baseline, comparison is
the candidate; `--candidate-contracts` then applies only to the candidate.

The workflow covers all eight tools using an exact 1 MiB JSON mutation fixture,
Markdown graph/search fixtures, readonly discovery, and refusal of readonly writes.
Its optional candidate checks exercise grouped backlinks, continuation with a changed
page size, and incomplete coverage. The schema harness additionally checks that
contradictory coverage and incomplete locator pairs are rejected by the schema.

Each request has one 45-second deadline covering queued writes, pipe writes, and the
response wait. A failed write makes that client connection unusable. Nonzero or forced
server shutdown fails validation; primary, shutdown, and cleanup failures remain in the
report separately.

Retain all samples and failures. Times run from request write-start to complete-frame
arrival: server work is included, client JSON/schema decoding and independent Git
verification are not. Request serialization occurs before the timer. Run timing
comparisons without concurrent builds/tests, record background load and OS cache
conditions, and use at least 30 samples per variant. Report failures alongside
latencies; a formerly failing workload succeeding is availability, not a speedup.
Wire bytes are not model token counts or billing. The current candidate's measured
results and remaining checks are recorded in [v2 validation](V2-VALIDATION.md).
The fixed acceptance specifications are in [release gates](RELEASE-GATES.md).

For separate native PDF/PNG checks, run `native_workflow.py` with the same `--binary`
and `--sha` options. Start with `--samples 1`; use at least 30 for distributions.
It generates bounded native fixtures, checks metadata/rendering/import, measures
large-source memory separately from small-text memory, and exercises queued and
active cancellation plus restart. It retains fixture manifests and generated master
files in the evidence directory. Its RSS/latency thresholds are explicit engineering
targets in the script, not a guarantee for every PDF or image.

Run both native fixture and report-integrity tests with
`python -B -m unittest discover -s Benchmarks -p 'test_native*.py' -v`.

These suites do not certify every media format, huge namespaces, transport flooding,
or actual work-client/model behavior. Those require their dedicated Swift
regressions and workload measurements. See
[Client-level release check](CLIENT-EVALUATION.md) for the separate work-client and
second-client evaluation; do not infer that result from server benchmarks.
