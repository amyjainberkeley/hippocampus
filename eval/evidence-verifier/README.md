# Evidence verifier evaluation

This directory owns candidate semantic-verifier evaluation. A retrieval rank
is never counted as evidence support. Candidate models must be scored on the
disjoint corpus and must preserve source attribution through the
`EvidenceVerifier` contract in `core/brain`.

The initial MobileBERT QA candidate intentionally reuses
`eval/relevance-calibration/v1.json` so its result can be compared with the
retired score critic and MiniLM spike. That fixture has only direct-answer
cases. It is useful for rejecting a weak candidate, but it is too small and
does not cover the full ADR-0038 release contract.

```bash
python3.11 -m venv .venv-evidence
.venv-evidence/bin/pip install -r scripts/requirements-evidence-verifier.txt
.venv-evidence/bin/python scripts/convert_evidence_verifier.py \
  --output /tmp/MobileBertQA.mlpackage \
  --tokenizer-output /tmp/MobileBertQA-tokenizer \
  --compiled-output /tmp/MobileBertQA.mlmodelc
.venv-evidence/bin/python scripts/eval/evidence-verifier/mobilebert_candidate.py \
  --model /tmp/MobileBertQA.mlmodelc \
  --tokenizer /tmp/MobileBertQA-tokenizer \
  --output /tmp/mobilebert-candidate.json
```

The scorer exits nonzero while the candidate is unqualified. An output report
is still written so failed experiments remain inspectable.
