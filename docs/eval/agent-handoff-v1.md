# Agent Handoff V1 Evaluation

## Question

Can Hippocampus find useful local work evidence and hand a small, exact,
source-cited packet to an agent without claiming that retrieved text is a
verified answer?

This benchmark measures retrieval and `mci_context` handoff utility. It does
not measure answer generation. `trusted_answer_qualified` is structurally
fixed to `false` until a source-attributed evidence verifier passes its held-out
qualification gate.

## Production Path

Each task creates a disposable encrypted brain and prepares its events with the
same context-header and chunking helper used by capture ingestion. The hybrid
arm embeds documents and queries with the installed Arctic Embed S Core ML
model. Both arms call `LiveBrainReader::recall`, followed by
`LiveBrainReader::context`, which is the backend invoked by the read-only
`mci_context` MCP tool.

The corpus stores expected source identities rather than generated answers.
The scorer checks packet text only for exact synthetic facts that appeared in
those sources.

## Metrics

- `hit_rate_at` and `recall_at`: session-level ranked retrieval over 31
  answerable tasks.
- `semantic_relevance_at_3`: all six paraphrase tasks retrieve and hand off the
  expected source within rank three.
- `temporal_current_accuracy`: the current source is present.
- `superseded_exclusion_rate`: the current source is present and no labeled
  superseded source enters the packet.
- `contradiction_visibility`: both labeled sides enter the packet; this does
  not claim the system resolved them.
- `duplicate_ocr_suppression`: at least one relevant duplicate is present and
  at most one member of its duplicate group consumes a citation.
- `exact_provenance_validity`: required citations preserve nonzero event id,
  exact timestamp, app bundle id, window title, and URL.
- `abstention_accuracy`: recall and context both return typed no-match states,
  with no citations, on all five missing-fact tasks.
- `handoff_task_success`: every required source and exact fact fits the packet
  budget on the four multi-source workflow tasks.
- `bounded_packet_rate`: token and evidence counts remain within each task's
  explicit budget.

The fixed quality targets are stored in the report. Regression comparisons can
be added after a second implementation is measured; this first result is an
honest product baseline, not a tuned release threshold.

## Interpretation

Ranking, evidence selection, and answer trust are separate layers. A degraded
retrieval can still provide useful related observations to an agent, but it
cannot authorize a factual answer. The report therefore has independent
`retrieval_and_handoff_qualified` and `trusted_answer_qualified` fields. The
latter remains false regardless of these scores.

The accepted machine-readable result is
`docs/eval/agent-handoff-v1-result.json`, pinned by the adjacent SHA-256 file.

## Accepted Result

The September 2, 2026 run completed all 72 arm-task combinations against the
installed, checksummed Core ML model. The repository contained unrelated
concurrent FFI changes, which the report records, while every benchmark and
production dependency path used by this sidecar was clean at start.

Hybrid results:

- 29/31 answerable tasks hit at ranks 1, 3, and 5; MRR was 0.9355.
- Session recall was 0.6613 at rank 1 and 0.9355 at ranks 3 and 5.
- Semantic relevance was 6/6, contradiction visibility 5/5, exact provenance
  5/5, abstention 5/5, and multi-source handoff utility 4/4.
- Exact fact coverage was 42/44 and every packet remained within budget.
- Current evidence was present for 4/6 temporal tasks, but superseded evidence
  was excluded in 0/6. Duplicate OCR was suppressed in 0/5; all five cases
  consumed three citations for the same visible fact.

The lexical-only arm returned no ranked source for any of the 31 natural
language answerable tasks. All 36 lexical calls remained typed as degraded,
not trusted matches, and all packets stayed within budget. This is a useful
fallback failure signal: strict FTS candidate generation cannot carry the
agent-handoff product by itself.

The fixed quality gate therefore fails on temporal currency, supersession, and
duplicate OCR in the hybrid arm, and on every utility axis in the lexical arm.
Both `retrieval_and_handoff_qualified` and `trusted_answer_qualified` remain
`false`.
