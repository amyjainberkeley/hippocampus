# ADR-0038: Source-attributed evidence verification

- Status: Accepted (2026-09-02)
- Scope: local recall and agent context
- Supersedes: the score-only production role of the evidence critic in
  `core/brain/src/evidence_sufficiency.rs`

## Context

Retrieval ranking answers which stored events are closest to a query. It does
not establish that those events answer the query. The v1 six-feature logistic
critic used embedding similarity, rank margin, lexical coverage, retrieval-arm
agreement, and novel-token length. On its untouched split it reached only
`0.833` positive coverage with `0.333` negative false-positive rate. Its
`validation_qualified` bit therefore remains false.

The failure is architectural, not a threshold typo. The strongest feature was
novel-token length, and the semantic and lexical portions could describe
different top-ranked documents. Neither property represents entailment or
answerability.

The existing explicit person/count/duration/date relation guard remains useful
as a narrow negative veto. It is not a generic verifier and cannot promote a
candidate to trusted evidence.

## Decision

1. `HybridRetriever` may use a local `EvidenceVerifier` after candidate
   retrieval and ranking. The verifier returns one of `Supported`,
   `Contradicted`, or `Insufficient`.
2. Every support or contradiction verdict must cite one or more stable event
   IDs from the exact candidate set. Confidence must be finite and inside
   `[0, 1]`. Invalid confidence, invented provenance, model failure, or invalid
   output becomes the typed `EvidenceVerifierUnavailable` degradation. Ranked
   excerpts remain visible only as untrusted `related_context`.
3. The verifier receives query text plus ranked event IDs and canonical event
   text. It does not receive cosine, fusion, recency, or source-prior scores.
   This prevents a second rank threshold from masquerading as semantic proof.
4. The explicit relation veto runs before the generic verifier and can only
   abstain. A qualified verifier may promote support. Contradiction and
   insufficiency abstain at the current recall boundary.
5. Absence of a verifier returns the typed `EvidenceVerifierUnavailable`
   degradation. The old score critic stays inspectable behind test/stub hooks
   for regression archaeology, but production construction does not install it
   and it cannot ship as the authority.
6. A release verifier must pass a blind, scenario-disjoint corpus covering
   direct answers, paraphrase/coreference, temporal changes, contradictions,
   cross-document synthesis, provenance, absent answers, concrete distractor
   values, mixed evidence, source authority, OCR corruption, and adversarial
   untrusted content. Inputs include a proposed answer decomposed into atomic
   claims; outputs cite exact source spans or image regions for each claim.
   Qualification invokes the immutable signed runtime and reports positive
   coverage, false-support confidence bounds, citation precision/recall, and
   calibration. The work-memory benchmark remains acceptance-only and cannot
   tune the verifier.

## Public v2 fixture audit

The checked-in v2 corpus is retained only as a regression smoke test. Its
answer key is public, its 48 cases reduce to 24 short synthetic scenarios, and
its fit, calibration, and validation partitions repeat category and wording
templates. It also does not contain the proposed answer whose claims need
verification. Passing v2 therefore cannot set `validation_qualified` and
cannot authorize production `Matched` outcomes. The v2 scorer reports
`fixture_passed` separately and always reports `release_qualified: false`.

## Model decisions

### Qwen3-1.7B: rejected for interactive verification

The installed Qwen backend is an autoregressive brief author. It samples at
temperature `0.3`, permits up to 512 output tokens, and reruns a fixed
2,048-token stateless Core ML graph for each generated token. It has no KV
cache. The compiled artifact on the audit Mac is 3.2 GB and the MCP recall
process does not share the brief worker's model instance. Loading it into every
MCP server or invoking it for every query would make recall slower, larger, and
non-repeatable. A real Core ML run of the existing one-day `day_light` brief
fixture did not finish within `121.5` seconds and was terminated. It remains
suitable only for bounded asynchronous generation until replaced or reworked.

### MiniLM SQuAD2: rejected as the release verifier

`deepset/minilm-uncased-squad2` revision
`934656cdda79824eabf503ed56e15c01ddbdbe3f` was tested as a no-answer reader
against the existing disjoint calibration fixture. Using best-span logit minus
CLS no-answer logit and the minimum positive calibration score as the attainable
90% threshold produced:

| Split | Positive coverage | Negative false-positive rate |
|---|---:|---:|
| Fit | 1.000 | 0.417 |
| Calibration | 1.000 | 0.333 |
| Validation | 0.833 | 0.333 |

PyTorch inference on the audit Mac measured 7.7 ms median and 9.2 ms p95 over
54 candidate sets. This is a development measurement, not a Core ML claim.
The model confidently extracted placeholders such as `One` and
`Fresh flowers` from insufficient evidence. Good latency does not qualify bad
abstention, so this checkpoint is not a release dependency.

The next release candidate is a compact, permissively licensed encoder trained
on Hippocampus-owned answerability, contradiction, and insufficient-evidence
triples, with FEVER, VitaminC, and ANLI used as public behavioral references.
MiniLM and DeBERTa-v3-xsmall are benchmark candidates, not selected artifacts.

### MobileBERT SQuAD2: native runtime proven, release qualification rejected

`csarron/mobilebert-uncased-squad-v2` revision
`6d49c30d06c6042041039f6fe076b011f0c2053c` was converted to a fixed-shape,
384-token, FP32 Core ML program. The conversion is reproducible with
`scripts/convert_evidence_verifier.py` and the exact operator-only dependency
set in `scripts/requirements-evidence-verifier.txt`. The native Rust bridge
accepts only the model's three named Int32 inputs, searches context tokens only,
caps spans at 24 tokens, and returns a no-answer margin rather than claiming a
verdict.

Core ML and PyTorch logits matched to a maximum absolute delta of
`0.00014687`. On the 54 candidate sets in the existing disjoint fixture, native
Core ML inference measured 23.49 ms median and 25.17 ms p95 on the audit Mac.
The minimum calibration threshold retaining at least 90% positive coverage was
`8.024189`. That threshold retained 100% of validation positives but falsely
accepted one of six validation negatives, for a 16.7% false-positive rate
against the 5% target. Across all splits it extracted unsupported placeholders
including `music`, `One`, `One room`, `a marked trail`, and `Fresh flowers`.

The candidate therefore remains unqualified. The committed report is
`docs/eval/mobilebert-qa-candidate.json`; its scorer intentionally exits
nonzero. The result proves that a small native QA model fits the interactive
latency budget. It also proves that span confidence from generic SQuAD2 training
is not a sufficient authorization rule for durable personal memory.

## Evidence

- SURE-RAG separates topical retrieval from support, contradiction, and
  uncertainty: https://arxiv.org/abs/2605.03534
- UAEval4RAG evaluates answerable accuracy and unanswerable rejection jointly:
  https://aclanthology.org/2025.acl-long.415/
- Grounded claim checking with small language models supports constrained local
  verification instead of open generation:
  https://aclanthology.org/2026.acl-long.1468/
- FEVER defines supported/refuted/not-enough-information evidence judgments:
  https://aclanthology.org/N18-1074/
- VitaminC supplies contrastive factual revisions for evidence sensitivity:
  https://aclanthology.org/2021.naacl-main.52/
- ANLI supplies adversarial entailment, contradiction, and neutral cases:
  https://aclanthology.org/2020.acl-main.441/
- Apple documents transformer optimization for the Neural Engine, while still
  requiring model- and hardware-specific measurement:
  https://machinelearning.apple.com/research/neural-engine-transformers

## Consequences

- Trusted `Matched` results now have a model-agnostic, provenance-checked seam.
- A missing model remains useful but visibly degraded rather than pretending
  retrieval rank is truth.
- The immediate development app does not become launch-qualified from this ADR
  alone. A redistributable model, Core ML parity test, locked qualification
  corpus, and minimum-Mac latency gate are still required.
- The verifier can evolve independently of FTS/vector ranking and independently
  of the asynchronous brief author.
