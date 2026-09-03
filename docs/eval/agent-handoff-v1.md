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
workspace changes, which the report records, while every benchmark and
production dependency path used by this sidecar was clean at start. Both arms
passed their fixed retrieval and handoff quality gates.

Hybrid results:

- All 31 answerable tasks hit at ranks 1, 3, and 5; MRR was 1.0.
- Session recall was 0.7258 at rank 1 and 1.0 at ranks 3 and 5.
- Semantic relevance was 6/6, temporal currency 6/6, superseded exclusion 6/6,
  contradiction visibility 5/5, exact provenance 5/5, abstention 5/5, and
  multi-source handoff utility 4/4.
- Repeated screen OCR was collapsed to one canonical citation in all 5/5
  duplicate cases; the lossless event store remains unchanged.
- Exact fact coverage was 44/44, every packet remained within budget, and all
  36 capability tasks passed.

Lexical-only results:

- Hit@1 was 0.8710, Hit@3 and Hit@5 were 1.0, and MRR was 0.9247.
- Session recall was 0.5968 at rank 1 and 0.9892 at ranks 3 and 5.
- Temporal currency, superseded exclusion, contradiction visibility, duplicate
  suppression, exact provenance, and abstention all scored 1.0.
- Multi-source handoff utility was 3/4, exact fact coverage was 43/44, every
  packet remained within budget, and 35/36 capability tasks passed.

The accepted result sets `retrieval_and_handoff_qualified` to `true`.
`trusted_answer_qualified` remains `false`: these scores qualify evidence
retrieval and bounded context transfer, not generated factual answers.
