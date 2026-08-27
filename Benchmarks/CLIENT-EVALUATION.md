# Client-level release check

Real-stdio tests verify the server, not model tool choices or host billing. Before
publishing, repeat these fixed tasks in the work client and one other supported
client, using a disposable synthetic vault, never personal or work content.

Record the binary SHA, client version, model, reasoning setting, exact prompts and
fixture manifest. Compare each client with itself across binaries. Start a fresh
conversation per task and restart every server process when changing binaries.

| Task | Fixture | Required outcome |
|---|---|---|
| Find one fact | Unique marker late in a large Canvas node | Search returns the right node/field; one selected read retrieves it without paging through unrelated JSON. |
| Navigate backlinks | Two source notes, one with many repeated links | Default results identify both sources with correct counts; drill-down only when occurrences are requested. |
| Handle incomplete discovery | Healthy matching note plus invalid UTF-8 source | Use healthy evidence without concluding that unexamined content has no matches. |
| Inspect metadata only | Long Markdown note and native PDF with known facts | Use metadata view; receive no body/page content; respect omission flags. |
| Continue search | More matches than one page, then a controlled edit | Unchanged continuation reaches all expected matches; stale cursors cause fresh searches, not identical retry loops. |
| Recover a stale write | Two sessions read a note; one edits it | The other observes conflict, reads current state, and reconsiders without overwriting blindly. |

Use identical immutable fixture bytes for comparable trials; record controlled
changes and restore the disposable fixture between trials. Older unsupported
workflows are availability comparisons, not percentage speedups.

Retain for every trial:

- Success and exact expected/observed facts.
- Tool calls, arguments, result sizes, retries and repeated identical failures.
- End-to-end task time separately from server request latency.
- Model-visible discovery and result projection, including whether the host shows
  both text and structured output.
- Actual input/output/cached tokens and cost only when exposed by the client;
  otherwise mark unavailable. Wire bytes are not billing estimates.

Run at least five fresh conversations per task/client for an exploratory check.
Every task must return the correct result, with no silent omission, unsafe write,
or repeated identical-failure loop. Report all failures and variability, not just
the best interaction. This small check does not establish a reliable model-cost
percentage or guarantee behavior for every model.
