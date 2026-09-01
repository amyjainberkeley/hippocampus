# Evidence-sufficiency calibration v1

This fixture calibrates a generic local evidence critic independently of the
Task 3 work-memory benchmark. It does not reuse Task 3 questions, entities,
sessions, source text, or labeled answers. Task 3 is an acceptance set only.

## Frozen protocol

- `v1.json` contains 18 everyday-life cases: 6 fit, 6 calibration, and 6
  untouched validation cases. Each case contributes one sufficient and one
  closely related but insufficient three-document candidate set.
- Feature schema v1 contains raw Arctic Embed S cosine, raw top-1/top-2
  semantic margin, bidirectional lexical coverage, and lexical/semantic top-1
  agreement. It contains no query text, entity names, slot labels, answer
  categories, query-local min-max score, clock input, or Task 3 labels.
- A five-feature logistic critic is fit only on the 12 observations in the
  `fit` split with fixed full-batch optimization: 20,000 iterations, learning
  rate 0.02, and L2 penalty 0.01.
- The threshold is the attainable lower positive split-conformal quantile for
  90% target positive coverage. Only the six positive `calibration` examples
  select it. Calibration negatives and all validation labels are excluded from
  threshold selection.
- Validation qualification was fixed before validation: positive coverage at
  least 0.90 and negative false-positive rate at most 0.10.

Run the deterministic maintainer tool from the repository root:

```sh
cargo run -p mci-agent --bin mci_calibrate_evidence -- \
  eval/relevance-calibration/v1.json \
  eval/relevance-calibration/v1-policy.json
```

`v1-policy.json` records every feature vector, fitted parameter, threshold,
split metric, model path, and the fixture SHA-256. Production constants are
pinned to that artifact by `core/brain/tests/evidence_sufficiency.rs`.

## Result

The critic did not qualify. Calibration positive coverage was 1.000 with
0.833 negative false-positive rate. Untouched validation positive coverage was
0.667 with 0.500 negative false-positive rate. The production policy therefore
keeps `validation_qualified=false`: scores remain inspectable, but cannot
promote a ranked candidate to `Matched`.

This follows the separation between retrieval and evidential sufficiency
motivated by [Chakraborty et al.](https://arxiv.org/abs/2511.17908),
[Liu et al.](https://arxiv.org/abs/2605.01302),
[S2G-RAG](https://aclanthology.org/2026.acl-long.1185/), and
[Xie et al.](https://aclanthology.org/2026.eacl-long.361/). The failed result is
kept rather than replaced with a Task 3-shaped heuristic.
