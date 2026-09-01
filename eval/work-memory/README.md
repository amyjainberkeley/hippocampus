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
production Core ML hybrid path.

## Run

```bash
scripts/eval/work-memory/run.sh
```

Update the committed baseline after an intentional benchmark change:

```bash
scripts/eval/work-memory/run.sh --update-baseline
```

For a one-off report:

```bash
scripts/eval/work-memory/run.sh --out /tmp/work-memory-report.json
```
