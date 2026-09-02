# Evidence verifier v2 public regression smoke

This fixture cannot qualify a release verifier. Its answer key is public, its
scenario families repeat across splits, and it does not receive or score a
proposed answer. It exists to test the three-way verdict and exact-citation
contract quickly. Release qualification requires the blind, claim-level,
signed-runtime evaluation defined by ADR-0038.

The v2 evaluation separates evidence verification from retrieval and model
execution. A candidate system receives each case's query, ordered
`candidate_ids`, and the canonical evidence text for those IDs. It writes a
JSON verdict file; the deterministic qualifier only checks that output against
the locked corpus. Retrieval rank, similarity, and generated prose never count
as evidence.

## Locked corpus

- Corpus: `eval/evidence-verifier/v2-corpus.json`
- Lock: `eval/evidence-verifier/v2-corpus.json.sha256`
- Dataset ID: `hippocampus-evidence-verifier-v2`
- Size: 48 cases across 24 scenarios
- Splits: 16 cases and 8 exclusive scenarios in each of fit, calibration, and validation

Every split covers direct answers, paraphrase and coreference, temporal
updates, contradiction, cross-document synthesis, provenance enforcement,
absent answers, and concrete distractors. Each split also has a supported and
an insufficient candidate-order metamorphic pair. Candidate evidence IDs and
source text are canonical. Changing any byte in the corpus invalidates the
lock and requires an intentional new corpus version or lock review.

## Verdict contract

The candidate writes one result for every case and no others:

```json
{
  "schema_version": 1,
  "dataset_id": "hippocampus-evidence-verifier-v2",
  "system": {
    "name": "candidate-name",
    "version": "immutable-version-or-artifact-id"
  },
  "verdicts": [
    {
      "case_id": "case-fit-cedar-release-time",
      "verdict": "supported",
      "citations": ["ev-fit-cedar-001"]
    }
  ]
}
```

`verdict` must be `supported`, `contradicted`, or `insufficient`.
`citations` contains only candidate evidence IDs. Supported and contradicted
results must cite one exact allowed evidence set; this prevents a plausible
answer from borrowing an unrelated candidate as provenance. Insufficient
results must have no citations.

Malformed JSON, duplicate or missing case results, unknown case IDs, invalid
verdict labels, and non-array citations return exit 2. Structurally valid but
unsafe output, including invented citations, non-candidate citations, wrong
verdicts, or order-sensitive answers, produces a report and returns exit 1.
Only a result that passes this public fixture returns exit 0. Every score report
sets `evaluation_scope` to `public_regression_smoke`, reports the result as
`fixture_passed`, and keeps `release_qualified` false.

## Commands

```bash
python3 scripts/eval/evidence-verifier/qualify_v2.py validate \
  --corpus eval/evidence-verifier/v2-corpus.json

python3 scripts/eval/evidence-verifier/qualify_v2.py self-test \
  --corpus eval/evidence-verifier/v2-corpus.json

python3 scripts/eval/evidence-verifier/qualify_v2.py score \
  --corpus eval/evidence-verifier/v2-corpus.json \
  --verdicts /path/to/candidate-verdicts.json \
  --output /tmp/evidence-verifier-report.json

python3 scripts/eval/evidence-verifier/test_qualify_v2.py
```

`--skip-lock` exists only for focused temporary-corpus tests. Qualification
runs should always use the checked-in SHA-256 lock.

## Smoke Metrics

The report computes every metric for fit, calibration, and validation, but the
fixture thresholds apply to the public validation partition only:

| Metric | Validation threshold |
|---|---:|
| Positive support coverage | at least 90% |
| Contradiction coverage | at least 90% |
| Insufficient false-positive rate | at most 5% |
| Provenance validity | 100% |
| Candidate-order metamorphic consistency | 100% |

Support and contradiction coverage require both the correct verdict and valid
provenance. The false-positive metric counts any non-insufficient verdict on
an insufficient case. Provenance validity is case-level and fails for
invented, non-candidate, missing, extra, or verdict-incompatible citations.
Metamorphic consistency requires a reordered pair to preserve its verdict and
citation set.

The corpus is synthetic and deterministic. It is a regression smoke test, not a
claim about real user prevalence, retrieval quality, answer correctness, or
release readiness.
