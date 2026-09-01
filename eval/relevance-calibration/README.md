# Evidence-sufficiency calibration v1

This fixture calibrates a generic local evidence critic independently of the
Task 3 work-memory benchmark. It does not reuse Task 3 questions, entities,
sessions, source text, or labeled answers. Task 3 remains an acceptance set.

## Frozen protocol

- `v1.json` contains 27 everyday-life cases: 12 fit, 9 calibration, and 6
  untouched validation cases. Each contributes one sufficient and one closely
  related but insufficient three-document candidate set.
- Nine positive calibration examples are the minimum sample size that can
  support the requested 90% one-sided split-conformal rank. The calibrator
  rejects smaller or otherwise unattainable `(sample size, coverage)` pairs.
- Feature schema v2 contains raw Arctic Embed S cosine, raw top-1/top-2
  semantic margin, bidirectional lexical coverage, lexical/semantic top-1
  agreement, and a domain-neutral novel-term specificity signal. Stable
  candidate identity is the final tie-break for equal scores.
- The feature schema contains no query text, entity names, slot labels, answer
  categories, query-local min-max score, clock input, or Task 3 labels.
- A six-feature logistic critic is fit only on the 24 observations in the fit
  split with fixed full-batch optimization: 20,000 iterations, learning rate
  `0.02`, and L2 penalty `0.01`.
- The threshold is the attainable lower positive split-conformal quantile for
  90% target positive coverage. Only the nine positive calibration examples
  select it. Calibration negatives and all validation labels are excluded from
  threshold selection.
- Qualification requires both calibration and validation positive coverage
  `>= 0.90` and negative false-positive rate `<= 0.10`.

Run the deterministic maintainer tool from the repository root:

```sh
MCI_ARCTIC_MODEL_PATH=/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc \
cargo run -q -p mci-agent --bin mci_calibrate_evidence -- \
  eval/relevance-calibration/v1.json \
  eval/relevance-calibration/v1-policy.json
```

`v1-policy.json` records every feature vector, fitted parameter, threshold,
split metric, model path, and the fixture SHA-256. Production constants are
pinned to that artifact by `core/brain/tests/evidence_sufficiency.rs`.

## Result

Fixture SHA-256:
`e18aba01ab344da3a1ee4ab58003e28bb86c041e99107b223073bfa7830ead5d`.
The threshold is `0.31316441644765064`.

The critic did not qualify. Calibration positive coverage was `1.000` with
`0.889` negative false-positive rate. Untouched validation positive coverage
was `0.833` with `0.333` negative false-positive rate. Production therefore
keeps `validation_qualified=false`: scores remain inspectable, but cannot
promote ranked candidates to `Matched`.

This follows the separation between retrieval and evidential sufficiency
motivated by [Chakraborty et al.](https://arxiv.org/abs/2511.17908),
[Liu et al.](https://arxiv.org/abs/2605.01302),
[S2G-RAG](https://aclanthology.org/2026.acl-long.1185/), and
[Xie et al.](https://aclanthology.org/2026.eacl-long.361/). The failed result is
kept rather than replaced with a Task 3-shaped heuristic.
