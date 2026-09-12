# Agent Handoff Runner

The runner measures the production local-memory handoff in two steps:

1. The standalone Rust harness prepares synthetic events with
   `brain_ingest::prepare_event_content`, writes disposable SQLCipher brains,
   and calls `LiveBrainReader::recall` plus `LiveBrainReader::context`, the
   backend used by the `mci_context` MCP tool.
2. The Python scorer compares the raw output with the locked corpus labels and
   writes exact per-case and aggregate metrics.

The harness is an eval-only Cargo package. It depends on production crates by
path but does not add code or dependencies to the shipped application.

Run a one-off report:

```bash
scripts/eval/agent-handoff/run.sh --out /tmp/agent-handoff-v1.json
```

Run one arm while developing the harness:

```bash
scripts/eval/agent-handoff/run.sh --arm lexical --out /tmp/agent-handoff-lexical.json
scripts/eval/agent-handoff/run.sh --arm hybrid --out /tmp/agent-handoff-hybrid.json
```

Promote a clean, complete two-arm report:

```bash
scripts/eval/agent-handoff/run.sh --update-result
```

The update command pins both the result and its SHA-256 sidecar. It refuses a
single-arm result, a modified corpus, an unavailable Core ML model, incomplete
cases, or dirty benchmark/production dependency paths. Unrelated working-tree
changes are recorded separately but do not alter the eval package's dependency
graph.

