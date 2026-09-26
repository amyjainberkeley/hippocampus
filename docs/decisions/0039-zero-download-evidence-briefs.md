# ADR-0039: Zero-download evidence-cited briefs

- Status: Accepted (2026-09-02)
- Scope: local brief authoring, onboarding, and release packaging
- Supersedes: ADR-0028 sections 4, 7, its 2026-05-28 shipping amendment,
  and ADR-0035 sections 5-6 for default model packaging

## Context

Daily briefs are useful only when they are available on first launch and do
not invent work. The previous default depended on a Qwen3-1.7B FP16 Core ML
artifact that was about 3.2 GB installed, used a fixed 2,048-token stateless
graph without a KV cache, and had passed only four of eight synthetic brief
fixtures. A real `day_light` generation on the audit Mac did not complete in
121.5 seconds and was terminated. The public download URL embedded in the app
returned HTTP 401 on 2026-09-02.

That is not a launch dependency. It is an unqualified experimental writer.
The event ledger already contains canonical text, timestamps, application
identity, and stable event IDs, so it can produce a concise, inspectable brief
without open-ended generation.

## Decision

1. `ExtractiveBriefAuthor` is the production default. It removes capture
   headers, normalizes and deduplicates OCR churn, prioritizes explicit changes
   and open loops, emits at most nine bullets, and attaches an exact canonical
   event citation to every bullet.
2. Brief generation must work with no account, network request, or generative
   model download. The CLI, scheduled worker, onboarding, menu, and persisted
   model provenance all describe that same behavior.
3. Snowflake Arctic Embed S remains the only required release model. It powers
   semantic candidate retrieval. Tier-1 entity extraction remains active when
   optional BERT NER is absent.
4. Qwen support remains available to custom builds that deliberately provide a
   complete model and tokenizer. Standard builds do not bundle it, advertise a
   download, or fail release assembly when it is absent.
5. A generative author may return to the public product only after its artifact
   is anonymously reachable, immutable and checksum-pinned, its latency and
   memory meet the minimum-Mac budget, and it beats the extractive baseline on
   the locked brief corpus without reducing citation validity.
6. Generated fluency never becomes the evidence authority. Canonical events
   remain the source of truth, and any generated claim must retain resolvable
   source attribution.

## Evidence

- Apple's Core AI guidance recommends beginning custom on-device model work at
  roughly 0.6B parameters and measuring on target hardware:
  https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session
- Qwen's model card identifies Qwen3-1.7B as a 1.7B-parameter model and records
  its upstream context and license properties:
  https://huggingface.co/Qwen/Qwen3-1.7B
- FactCC demonstrates that fluent summaries require a separate factual
  consistency discipline:
  https://arxiv.org/abs/1910.12840
- QAGS evaluates summaries by checking whether source documents support their
  generated answers:
  https://arxiv.org/abs/2004.04228
- SummaC finds that natural-language-inference consistency signals transfer
  unevenly and require task-specific validation:
  https://arxiv.org/abs/2111.09525

The product choice is an inference from those sources plus the repository's
measured artifact behavior. None of the papers proves that this specific
extractive implementation is sufficient; the locked local benchmark and user
inspection must establish that.

## Consequences

- A fresh user receives a useful, private brief immediately instead of a large
  download dialog or a disabled feature.
- Release size drops by several gigabytes and first-run availability no longer
  depends on a model host.
- Brief prose is intentionally less polished than a qualified generative
  model, but every surfaced item is inspectable and source-cited.
- Qwen conversion and runtime code can remain for experimentation without
  distorting the public product or installer contract.
- This ADR does not qualify the semantic evidence verifier. Retrieval trust and
  brief authoring remain separate measured gates.
