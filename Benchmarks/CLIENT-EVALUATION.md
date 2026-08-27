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

## Focused retest of the work-agent feedback fixes

After obtaining the follow-up commits, build with
`swift build -c release --force-resolved-versions`, record the source commit and
binary SHA, and fully restart every client/server using the disposable vault.
Refresh tool discovery; rebuilding alone does not replace an already running MCP.
The checked-in `Vendor/swift-sdk` is required; do not omit it when transferring
the changes. No client configuration or personal vault file needs deletion.

| Check | Required observation |
|---|---|
| Literal text | Create a log containing exactly `data:text/plain,Hello%20World` (no newline), then read it. It remains exactly 29 UTF-8 bytes, with matching text-window metadata and revision; no binary-type rejection or base64 rewriting. |
| Path recovery | A destination without `notes/` is rejected with an explicit example. Correct it once and confirm success; do not retry the unchanged invalid request. |
| Canvas recovery | A root array is rejected with an object-shape example. A valid object such as `{"nodes":[],"edges":[]}` succeeds. |
| Metadata recovery | `view=metadata` with `max_bytes` names that conflict. Omitting the selector succeeds and returns no body or image. |
| Media creation | Use generated regular files outside the vault: PNG/image import and a supported short video with `transform=video_to_gif`. Confirm successful reads and unchanged source files. In-vault and data-URI sources remain rejected with corrective guidance. |
| Discovery recovery | With a known unhealthy source, recognize incomplete coverage and narrow directory/formats. For `[[Target|Display name]]`, query the target, not its per-link display label. |
| Parallel safety | Repeat independent reads/searches in parallel and one controlled stale-write conflict. Verify exact results, bounded recovery, no crash, and no identical-failure loop. |

Retain all failed attempts as well as successful repairs, and distinguish raw MCP
text from any client-side display transformation. Clean up only fixtures created
for this run, using recoverable deletion. This focused retest supplements, rather
than replaces, the client-level qualification tasks above.

Run at least five fresh conversations per task/client for an exploratory check.
Every task must return the correct result, with no silent omission, unsafe write,
or repeated identical-failure loop. Report all failures and variability, not just
the best interaction. This small check does not establish a reliable model-cost
percentage or guarantee behavior for every model.
