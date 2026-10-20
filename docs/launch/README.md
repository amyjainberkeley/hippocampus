# Launch safety checkers

Four runnable checks a careful reader would ask for before trusting
Hippocampus with their screen. Each one is an **outside judge**: it runs,
prints a table, and exits pass/fail — no self-assessment. They are
content-free (they read counters, source, and byte sizes, never the brain,
the screen, or captured text), and they build/connect to nothing except the
synthetic fixtures they create under `$TMPDIR`.

Run them from the repo root. None of them needs root.

| Check | Script | Proves | Exit |
|---|---|---|---|
| Egress audit | `scripts/launch/no-egress.sh` | Every line that can open a connection is the update check or loopback — nothing else | non-zero on any unexpected network code |
| At-rest encryption | `scripts/launch/verify-encryption.sh` | The brain is SQLCipher; no plaintext capture text on disk; the key is in the Keychain | non-zero if any proof fails |
| No open port | `scripts/launch/no-listener.sh` | No Hippocampus process listens on a TCP port (IPC is AF_UNIX only) | non-zero if any process listens |
| Footprint | `scripts/launch/footprint.sh` | CPU / memory / disk-growth of every Hippocampus process, vs the budgets | non-zero only if a never-cross ceiling is crossed |

For the runtime side of the egress claim — watching live traffic for a full
day with `nettop` / `lsof` / Little Snitch — see
[`network-check.md`](network-check.md). That one you run; a build script
can't watch for 24 hours.

## What each one checks, and why you can trust it

### `no-egress.sh` — the network boundary, from the source

Greps every shipping crate and Swift/Python/JS file for the APIs that
actually open a socket or make a request (not URL *strings*, which are
data), then classifies each file against an allowlist ledger in the script.
Build outputs (`.build/`, `target/`, `.venv/`, `build/`, `dist/` and the
like) are skipped, so a built checkout gets the same answer as a clean
export (`scripts/test-no-egress.sh`):

- **(a) UPDATE** — Sparkle polls the signed appcast on the GitHub releases
  host (`apps/hippocampus/Resources/Info.plist`). This is the one
  destination that is not on your Mac.
- **(b) LOOPBACK** — the local model server (Ollama / LM Studio;
  `LocalServerEngine.local()` rejects any host but `127.0.0.1`/`::1`) and an
  opt-in loopback MCP server (`core/mcp-client` dials only through
  `LoopbackOnlyConnector`, validated at registration **and** connect time).
- **GUARD / IPC / BUILD-ONLY / COMMENT** — e.g. the OCR worker installs an
  audit hook that *blocks* `socket.connect`/`bind`; helper IPC is AF_UNIX.

Anything not on the ledger is **UNEXPECTED** and fails the run. The ledger
is the point: a new file that opens a socket must be reviewed and added.
The run also enforces hard invariants — no general HTTP client crate
(`reqwest`/`ureq`/…) in the shipping Rust, `hyper`/TCP confined to the
loopback transport, `URLSession` calls confined to the loopback model
client, no TCP/UDP listener, and the Sparkle feed is `https` on
`github.com`.

### `verify-encryption.sh` — encrypted at rest, key in the Keychain

Builds and runs `core/brain/tests/at_rest_cli_proof.rs`, which writes a
unique plaintext canary through the real `SqlCipherBrainStore` into a
**synthetic** store under `$TMPDIR`, then proves: the canary appears in
**zero** bytes of any store file; the file has no unencrypted `SQLite
format 3` header; a keyless open cannot read it; no key file sits beside it.
It then cross-checks the same file with the **system `sqlite3` CLI** (an
independent tool — a raw open reports "file is not a database"), runs the
store-layer round-trip (`mci-core`) and the brain-store suite, and runs the
`KeychainDatabaseKeyResolverTests` that show the key is read from the
Keychain via `SecItemCopyMatching`. It never touches the real brain.

### `no-listener.sh` — nothing to connect *to*

Finds every running process inside `Hippocampus.app` and asks `lsof` whether
any holds a TCP socket in `LISTEN`. Hippocampus accepts no inbound
connections; its helpers talk over Unix-domain sockets. Outbound loopback
connections are `ESTABLISHED`, not `LISTEN`, so they're correctly out of
scope here.

### `footprint.sh` — what it costs, honestly

Compiles the content-free sampler `hippo_footprint.c` (reads
`proc_pid_rusage` counters only), samples ~60 s across every Hippocampus
process, and prints CPU (as % of one core and of the whole machine, mean +
p95), total resident memory, and the store's disk growth, against the
budgets in `reports/launch-design/budgets.md`. It fails only if a
never-cross **ceiling** is crossed; missing a stricter **target** prints a
yellow WARN, because that is the honest state of 0.3.0.

## Honest limits (read before quoting a number)

- `footprint.sh` is a **snapshot**, not the scripted "normal hour"
  (`budgets.md` §5.1). A quiet minute looks great; the expensive minute is
  when the PP-OCR reader runs, where `budgets.md` already records memory
  **over** its target (0.7–1.65 GB during a read) and CPU p95 at the
  ceiling while the screen keeps changing. Run the scripted hour before
  making a footprint claim in public.
- `no-egress.sh` reasons about **code**. The proof that nothing *actually*
  dials out on your Mac over a day is the human runtime watch in
  `network-check.md`.
- It reads first-party source only. Third-party native code is outside its
  view: the text reader's ONNX Runtime carries Microsoft's telemetry client,
  which the worker turns off and the helper runs with the network denied. A run of the
  shipped worker with no network (`scripts/lib/ocr_offline.py`, in the
  release and the `ocr-worker` lane) and the storage audit's `net.binary`
  and `net.runtime-log` checks cover that.
- The budgets themselves (download 180 MB, installed size, energy) are
  measured elsewhere; these four checkers cover network, encryption,
  listeners, and live footprint.
