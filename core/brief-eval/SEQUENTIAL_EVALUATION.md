# Sequential Work Memory Policy Fixture

`sequential-memory-eval` is an offline, deterministic policy regression in the
existing eval crate. It is **not an actual-agent learning experiment**. It uses
the production `MemoryClaim`, `MemoryDelta`, SQLCipher projection, bitemporal
read, evidence expansion, and deletion APIs. It introduces no production memory
store, schema, confirmation classifier, or authorization mechanism.

## Protocol V1

`fixtures/sequential/v1/world.json` contains a chronological synthetic sequence.
The separate `gold.json` contains literal expected validation plans for 14 new
task targets. A task asks for a plan, never execution. Neither gold answers nor
future observations are provided to the planner. Historical tasks use explicit
valid-time and known-time coordinates.

Each arm gets the same task-world prefix and current task, identified by a
SHA-256 digest. Each arm/run creates its own disposable encrypted store and
ephemeral key. No installed brain, credentials, model, private memory, writable
project, or persistent client session is used. Temporary stores are removed
after each arm. Stateless requests contain no history even though the fixture
world continues to change.

| Arm | Context selection |
| --- | --- |
| Stateless | Current task only |
| Simple context | Last two retained observations eligible at the task's known-time cutoff for the exact project, in receipt order; replay adds a receipt; direct source deletion removes its receipts |
| Governed memory | Active claims from the production bitemporal projector, restricted to the exact project, with bounded canonical evidence expansion |

All arms share the same deterministic planner and 16 KiB serialized-request
limit. The planner scans context from most recent to oldest and accepts only
active, project-matching, temporally valid rules. Governing supersession and
dependency deletion are features of the production projector. The simple
baseline does not independently implement that projector. It is a specified
recent-history baseline, not a full-history or best-possible agent baseline.

Owner confirmation is explicit, synthetic fixture metadata. A malicious screen
observation remains `Proposed` regardless of what its text says. Source-backed
claims are not generally proof of owner authorization: the fixture supplies that
distinction; this eval does not claim the product infers it automatically.

Cases cover positive transfer, stale replay, named correction, process change,
historical state, inclusive expiry, project isolation, malicious source text,
source deletion, recursive correction deletion, and independent surviving rules.
Regression tests also re-expand cached claim IDs after deleting an ancestor.
Deleted sources are evicted from the fixture registry. Numeric event-ID reuse
cannot make a replay or repeated deletion target a replacement event; source
retention checks bind the full stored identity. Privacy scoring also checks
the task's known-time cutoff rather than only its later wall time.
Already-exported client copies are outside local deletion guarantees.

## Running

Run from the repository root with an allowlisted environment and explicit paths:

```sh
env -i HOME="$HOME" \
  PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR=/tmp \
  cargo run --locked --offline -p mci-brief-eval --bin sequential-memory-eval -- \
  --out /tmp/sequential-memory-v1.json \
  --requests-out /tmp/sequential-memory-v1-requests.json
```

Reports include fixture/gold hashes, per-task outputs and failures, absolute
successes, harmful reuse (a wrong plan using a remembered rule), privacy failures
(cross-project, future, or deleted-source context), and success-count differences.
Logical ingestion/projection/replay/deletion/retrieval calls and serialized
request bytes are recorded separately. Elapsed time includes world setup,
ingestion, projection, scoring, and cleanup. It is not agent latency. Model calls
are zero; model token counts and provider cost are null, not measured zero cost.
The one authored sequence does not establish generalization or uncertainty.

## Client Boundary

`--requests-out` exports protocol-v1 JSON requests without gold answers. Each has
the current task, world digest, arm, source citations/status/scope/times, and
`plan_only_no_execution` permission. A response contains `request_sha256`,
`argv`, and `selected_source`. The digest binds the response to the serialized
typed request. `--policy-client` reads one request on stdin and returns one
deterministic response on stdout. Unknown fields, unsupported versions,
invalid coordinates, and over-budget requests are rejected.

`tests/sequential_client.rs` exercises this boundary through a fresh subprocess
with `env_clear()` and a disposable working directory. This is a scripted
protocol smoke test. No actual Claude/Codex/provider run is performed, and every
report sets `actual_client_run: false`. A future actual-agent evaluation must
record its client/model version, settings, permissions, costs and resets, use
these equivalent snapshots, and score the returned plans independently. Merely
exporting requests or passing this smoke test does not satisfy that experiment.
