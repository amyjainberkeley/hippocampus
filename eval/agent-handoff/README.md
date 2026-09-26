# Synthetic Agent Handoff Benchmark

`agent-handoff-v1.json` is a deterministic, synthetic acceptance corpus for
the local memory-to-agent boundary. It contains no user data.

## Coverage

The corpus has 36 isolated tasks:

| Capability | Tasks | What must be preserved |
|---|---:|---|
| Semantic relevance | 6 | Paraphrased intent reaches the right source and packet |
| Temporal supersession | 6 | Current evidence is present and superseded evidence is excluded |
| Contradiction | 5 | Both sides remain visible and cited without invented resolution |
| Duplicate OCR | 5 | Repeated screen text consumes at most one evidence slot |
| Exact provenance | 5 | Event id, timestamp, app, title, and URL match the seeded source |
| Abstention | 5 | Missing facts produce no ranked or packet evidence |
| Handoff utility | 4 | Multi-source facts and citations fit the caller's bounded packet |

Every instance uses the same `haystack_*`, `answer_session_ids`, query, and tag
shape as `eval/work-memory/synthetic-v1.json`. `handoff_expectation` adds the
packet-specific contract: required facts and sources, forbidden superseded
sources, contradiction pairs, duplicate groups, and exact token/evidence
budgets.

Regenerate the corpus deterministically and verify its pinned digest:

```bash
python3 eval/agent-handoff/build_corpus.py
test "$(shasum -a 256 eval/agent-handoff/agent-handoff-v1.json | awk '{print $1}')" = \
  "$(tr -d '[:space:]' < eval/agent-handoff/agent-handoff-v1.sha256)"
```

Do not tune this acceptance corpus from benchmark misses. A semantic change to
a label or fixture requires an explicit corpus revision and a new dataset id.
