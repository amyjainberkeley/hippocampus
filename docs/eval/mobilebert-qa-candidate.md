# MobileBERT QA evidence-verifier candidate

_Measured on 2026-09-02. This candidate is not release-qualified._

The candidate is `csarron/mobilebert-uncased-squad-v2` at immutable revision
`6d49c30d06c6042041039f6fe076b011f0c2053c`, converted to a fixed 384-token
FP32 Core ML program. Conversion and evaluation are reproducible from:

- `scripts/requirements-evidence-verifier.txt`
- `scripts/convert_evidence_verifier.py`
- `scripts/eval/evidence-verifier/mobilebert_candidate.py`
- `eval/relevance-calibration/v1.json`

The generated Core ML artifact used for this run had tree SHA-256
`b14fc28b633f7b9e43bd1b247a72428065dd133b03dd9528287ca3682c82451f`.
It is an experiment output, not a committed or release-owned model.

## Result

The threshold was selected only from the calibration split: choose the minimum
supporting-evidence no-answer margin that retains at least 90% positive
coverage. The resulting threshold was `8.024189`.

| Split | Cases | Positive coverage | Negative false-positive rate |
|---|---:|---:|---:|
| Fit | 12 | 100.0% | 33.3% |
| Calibration | 9 | 100.0% | 22.2% |
| Validation | 6 | 100.0% | 16.7% |

The release targets are at least 90% validation positive coverage and at most
5% validation false positives. The candidate misses the false-positive target.
The validation corpus also has only six scenarios and does not yet cover
contradiction, temporal change, synthesis, provenance, or candidate-order
metamorphics.

Native Core ML inference over 54 candidate sets measured 23.49 ms median,
25.17 ms p95, and 31.57 ms maximum on the audit Mac. PyTorch-to-Core-ML parity
passed with maximum absolute logit delta `0.00014687`.

## Failure shape

The model confidently extracts plausible-looking text even when the requested
fact is absent. False-positive spans above the selected threshold included:

- `music`
- `Rowan crossed the inlet before noon`
- `One`
- `One room`
- `a marked trail`
- `The button itself was undamaged`
- `Fresh flowers`

This is exactly the unsafe behavior the evidence layer must prevent. Fast span
extraction is useful plumbing, but it cannot authorize `Matched` memory without
an independently qualified support, contradiction, and abstention policy.

The machine-readable result is `docs/eval/mobilebert-qa-candidate.json`. The
evaluator writes that report and exits with status 1 while the candidate is
unqualified.
