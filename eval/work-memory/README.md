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

`complete` means every case in the requested run executed. `publishable` also
requires all 24 cases, both lexical and hybrid arms, `k=1,3,5,10`, a clean
committed code tree, and a checksummed Core ML model. `launch_qualified` is a
separate absolute quality gate. Regression thresholds detect change from the
measured baseline, but cannot bless a weak baseline that violates the fixed
quality targets.

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

Baseline generation refuses limited, single-arm, noncanonical-k, dirty-tree,
or otherwise nonpublishable reports. It can write an honest publishable
baseline and still return nonzero when the separate launch-quality gate fails.

For an intentional one-case smoke run that may exit zero:

```bash
scripts/eval/work-memory/run.sh --no-baseline --allow-smoke --limit 1 --arm lexical
```

Smoke reports always set `complete=false` and `publishable=false` and cannot be
accepted as baselines.

For a one-off report:

```bash
scripts/eval/work-memory/run.sh --out /tmp/work-memory-report.json
```
