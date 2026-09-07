# September 7 Memory Quality Checkpoint

## What This Measures

Synthetic pixels and SQLite fixtures, not personal captures, were used for
repeatable before/after tests. These measurements do not establish universal
OCR accuracy, semantic understanding, enterprise certification, or overnight
reliability. Installation and live qualification are recorded in `docs/STATUS.md`.

## Recognition

The previous accurate, raw Apple Vision pass missed all four short 12-pixel
labels on each large test canvas. Lowering `minimumTextHeight` did not recover
them. The new recognizer keeps that full-region pass and adds at most four
overlapping subregions, entirely within the already admitted region and
existing 1920-pixel capture canvas. It does not resample, use remote inference,
or enable whole-display capture.

Fresh optimized main-task run, five warm samples per sparse fixture:

| Fixture | Exact labels, old to new | Median milliseconds, old to new |
| --- | --- | --- |
| 1920 x 1080, 12-pixel text | 0/4 to 4/4 | 28 to 105 |
| 1920 x 1920, 12-pixel text | 0/4 to 4/4 | 25 to 158 |
| 1920 x 1080, 16-pixel text | 4/4 to 4/4 | 38 to 128 |

In three dense 80-line samples, all 81 original observations were preserved.
Median times were 415 to 399 ms; every optional subregion was skipped for
headroom. This is timing noise, not evidence of a speedup. Cold-start work can
exceed the 1,000 ms production deadline even in the old baseline. The guard
reserves twice the slowest observed pass before optional work, but is heuristic.
Timeouts discard every accumulated result and quarantine the lane until Vision
actually returns. No partial baseline is published after an overrun.

Review caught an important failed attempt: overlap deduplication removed a
repeated `password` label and separated it from a supplemental `: demo` line.
Both tests and actual Vision pixels reproduced the privacy failure. The final
implementation retains every completed pass contiguously, including duplicate
labels. The real-Vision regression now produces an `ocrTimeSecret` tombstone
and zero retention calls. This intentionally trades some duplicate text for
privacy coverage; deduplication must never precede complete-pass privacy checks.
The full optimized capture suite passed 691 tests. These are synthetic/runtime
component checks, not fresh installed capture proof.

## Retrieval

Pasted uppercase boolean words were interpreted as FTS operators, producing
errors or removing relevant results. They are now literal tokens. Broader
testing then caught a conflict with the agent's internally generated OR search.
The corrected boundary accepts typed keyword or exact-phrase alternatives and
encodes each branch before constructing OR syntax. Callers cannot inject a raw
FTS expression through this API. It bounds input to 1,024 alternatives and
128 KiB, uses SQL parameters, and retains BM25 ordering and stable ID ties.

SQLite tests cover literal code, quotes, operator-shaped text, phrase adjacency,
limits, deletion and suppressed-event rejection. MCP fallback remains explicitly
degraded without embeddings and still abstains when an answer relation is absent.
An internal alternative is a retrieval choice, not evidence that its result is
the answer. The FFI lexical fallback now passes dictionary aliases as literal
phrases, with deterministic count/byte budgets that preserve the original query
and skip oversized optional phrases whole. Ten real-SQLite FFI regressions cover
this path. Alias expansion in the hybrid path remains unchanged and is not
claimed fixed by these tests. Integrated qualification is tracked in STATUS.

## Daily Drafts

Browser-menu-only events could crowd out actual source excerpts. Exact Chrome
and Safari menu lines are removed only from the temporary author input, in the
matching browser context. Other apps and content containing those words remain.
At the 509-512-byte snippet boundary, an unterminated last line is omitted
because truncation might hide a negation or hypothetical qualifier. This is
conservative and can omit a complete final line of exactly that length; the
store currently has no explicit truncation flag. Original stored text is not
rewritten.

Synthetic end-to-end draft fixtures recovered both useful excerpts (0/2 to 2/2),
removed nine menu bullets, and removed four misleading clipped updates while
retaining their four complete preceding lines and source IDs. This is extractive
cleanup, not completed commitment tracking or deeper semantic reconciliation.

## Next Product Boundaries

1. More OCR coverage needs a held-out corpus spanning languages, small code,
   dark/light interfaces and difficult layouts, plus battery and cold-start
   measurements. Old missed text cannot be recovered by improving search alone.
2. A useful work brief needs full-evidence reading, contradiction handling,
   temporal updates, citations and abstention. Fluency is not the quality gate.
3. Activity insights need active/idle measurements and explicit unknown periods.
   A foreground app does not establish attention, distraction or productivity.
4. Planned-versus-completed work needs reviewable task records and confirmation,
   not an inference from a checkbox or sentence visible in a screenshot.
5. Broader co-visible capture needs explicit consent and per-window privacy
   classification under overlap and focus races. Unopened tabs are not pixels.
6. An eventual computer-history/undo experience must distinguish retrieving an
   observation from reversing a real action. Agent actions need separate grants,
   audit records and reversible operations where supported.

## Technical References

- [Apple: text recognition request](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [Apple: independent-window capture filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:))
- [SQLite: FTS5 query syntax and quoting](https://www.sqlite.org/fts5.html)

These primary documents describe the APIs. The repository fixtures, not the
documents, supply the before/after measurements above.
