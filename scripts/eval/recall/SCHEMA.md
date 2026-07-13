# Recall-eval schemas (scaffold)

## Corpus — JSONL, one row per case

| Field | Type | Notes |
|---|---|---|
| `query` | string | Non-empty natural-language recall input. |
| `expected_top_k` | array of string | Canonical event IDs the retriever MUST return in top-k. Order-independent; MRR scores the first expected hit. |
| `context_note` | string | One sentence (URL lookup / entity mention / cross-app dot-connect / temporal / semantic). Not scored. |

Optional (ignored by current judge; reserved for cycle 8.44+):
`category` (per-category rollups), `forbidden_event_ids` (anti-recall
— e.g. incognito must not surface), `notes` (author scratch).

All `evt-fake-*` IDs are synthetic. Cycle 8.44+ seed module emits
canonical events; the real corpus references those. No real user
brain content ships in this repo.

## Runner output — JSONL, one row per query

| Field | Type | Notes |
|---|---|---|
| `query` | string | Verbatim copy of corpus `query` (join key). |
| `expected_top_k` | array of string | Denormalized copy. |
| `hits` | array of string | Event IDs from `mci-brain search`, top-1 first. |

## Judge output — text

Tabular per-query + aggregate footer. Columns: `query` (38 chars),
`P@k`, `R@k`, `RR`. Footer averages P@k, R@k, RR (= MRR). Missing
cases print `(missing)` and are excluded from the average; the
scorecard workflow (cycle 8.44+) treats missing as a hard failure.

## Adding a case

1. Append a JSONL row matching required fields.
2. 1–3 expected IDs. More makes recall@k trivially high.
3. `context_note` names the retrieval mechanism exercised.
4. Synthetic only. No real user text.
