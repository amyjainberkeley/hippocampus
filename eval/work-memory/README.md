# Synthetic Work-Memory Benchmark

`synthetic-v1.json` is the committed Hippocampus work-memory corpus for V1.
It is synthetic only and contains no user data.

## Coverage

- 24 cases total
- 8 categories: exact recall, paraphrase, temporal, cross-session synthesis, changed facts, contradiction, source attribution, and unanswerable
- Source surfaces: GitHub, terminal, browser, Slack, Linear, and files

## Format

The benchmark accepts two dataset shapes:

- Legacy LongMemEval: top-level JSON array of instances
- Work-memory envelope: `{dataset_id, description, instances}`

Each instance keeps the LongMemEval fields and can add:

- `haystack_app_ids`
- `haystack_window_titles`
- `haystack_urls`
- `tags`
- `unanswerable`

The runner uses the real `SqlCipherBrainStore`, the lexical FTS path, and the
production Core ML hybrid path. Synthetic turns are prepared through the same
`compose_context_header` plus production `EventChunker` helper used by
`BrainPump`; persisted text and synchronous document-embedding input therefore
have production byte shape.

## Metric Semantics

- Hit rate, recall, MRR, and provenance coverage use answerable questions only.
- False-positive rate uses unanswerable questions only.
- Abstention separation is answerable hit rate minus unanswerable
  false-positive rate (`TPR - FPR`, a Youden-style separation), not abstention
  accuracy.
- Reports include explicit answerable and unanswerable denominators. A metric
  whose eligible denominator is zero is JSON `null`, never numeric zero.

The three unanswerable cases are plausible missing-fact questions about the
same projects, people, applications, and vocabulary as their evidence. They ask
for an absent PR approver, test duration, and Linear due date; the corpus does
not use nonsense-token negatives.

Those three negatives are an acceptance slice, not enough data to fit or tune
an abstention threshold. `explicit-evidence-relation-v2.json` is a disjoint
synthetic fixture for the narrow deterministic guard used before the broader
critic. Its six calibration and eight validation cases cover person, count,
duration, and date relations without reusing work-memory questions, entities,
sessions, or software facts. A separate eight-case adversarial split puts an
unrelated name, version, clock, prior date, weekday, or duration near the right
topic without a giveaway phrase saying the answer is missing. The fixture
SHA-256 is
`9eb9b90d703a248a8526aebd723672a429f7eabbb4b1f278727c5181f8c2ae3d`.

The guard is negative-only: when a query unambiguously requests one of those
four value types and no evidence body relates a value to the query subject and
predicate, production returns `NothingMatched(EvidenceFloor)`. A supported
relation does not promote evidence to `Matched`; only the source-attributed
semantic verifier may do that, and no release verifier is qualified yet.
Ingestion headers are removed before assessment so app names, titles, URLs, and
capture timestamps cannot satisfy a question. Sentence boundaries, local topic
anchors, and answer-type grammar prevent values from unrelated events from
being joined into an answer.

The committed fixture accepts all 6/6 calibration and 8/8 validation supporting
sets while rejecting every corresponding insufficient set. It also rejects all
8/8 unrelated-value adversarial sets, with zero false pass-throughs. The
positive enum value is therefore `RelationSupported`, and the qualification is
`relation_grounded: true`. This is evidence for the four explicit answer shapes
only, not a claim that general evidence sufficiency is solved. The retired
similarity-based critic remains inspectable behind test/stub hooks but cannot
authorize production evidence. The absent release verifier continues to block
`launch_qualified`. These small synthetic counts are regression evidence, not a
population-level accuracy claim.

Every per-case report includes `retrieval_disposition`, preserving whether the
production path matched, contradicted, abstained at a named reason, or returned
ranked context while the semantic verifier was unavailable. Benchmark outcome
labels therefore remain auditable without treating a fused rank score as
confidence.

`complete` means every case in the requested run executed. `publishable` also
requires all 24 cases, both lexical and hybrid arms, `k=1,3,5,10`, a clean
committed code tree, and a checksummed Core ML model. `launch_qualified` is a
separate absolute quality gate. Regression thresholds detect change from the
measured baseline, but cannot bless a weak baseline that violates the fixed
quality targets. Signed `TPR - FPR` regression floors preserve negative
source values, so every derived baseline accepts the metrics that produced it.

Each process owns a unique scratch subdirectory. Per-instance SQLite main,
WAL, and SHM files are removed by scope guards on success and error paths.
Index footprint is measured after the store closes and includes any remaining
main/WAL/SHM bytes, so it reflects indexed content rather than the live 4 KiB
main-file stub.

Run metadata records the clean commit, normalized command arguments, dataset
checksum, OS/build, architecture, hardware, compute mode, and a deterministic
SHA-256 content checksum over the sorted model-bundle file manifest. Paths
inside the repository are relative; external paths use stable logical labels
and never serialize user-home or temporary directory prefixes.

## Run

```bash
scripts/eval/work-memory/run.sh
```

Update the committed baseline after an intentional benchmark change:

```bash
scripts/eval/work-memory/run.sh --update-baseline
```

The update promotes the canonical report and refreshes its single pinned
SHA-256 sidecar. A normal run refuses a missing, malformed, or mismatched
sidecar before invoking the benchmark.

Baseline generation pins `eval/work-memory/synthetic-v1.json` and refuses
dataset overrides, limited or single-arm runs, noncanonical k values, dirty
trees, any dataset id other than `synthetic-work-memory-v1`, and any count
other than exactly 24 original and 24 evaluated cases. An ineligible candidate
is deleted without replacing the output. A valid publishable baseline can
still return nonzero when the separate launch-quality gate fails.

For an intentional one-case smoke run that may exit zero:

```bash
scripts/eval/work-memory/run.sh --allow-smoke --limit 1 --arm lexical
```

Smoke reports always set `complete=false` and `publishable=false` and cannot be
accepted as baselines.

For a one-off report:

```bash
scripts/eval/work-memory/run.sh --out /tmp/work-memory-report.json
```
