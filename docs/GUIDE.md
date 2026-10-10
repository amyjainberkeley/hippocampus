# Hippocampus guide

The [README](../README.md) says what Hippocampus is and why it exists. This is the reference: how to inspect a brain, turn on semantic recall, connect other MCP servers, and fix things when they go wrong.

- [Inspecting a brain](#inspecting-a-brain)
- [Turning on semantic recall](#turning-on-semantic-recall)
- [Pulling in your other MCP servers](#pulling-in-your-other-mcp-servers)
- [Prerequisites](#prerequisites)
- [Commands](#commands)
- [Troubleshooting](#troubleshooting)

---

## Inspecting a brain

Real output from `./scripts/try-it.sh` (see the [quickstart](../README.md#quickstart)), not a mockup.

One thing to be straight about before you read it: `mci-brain search` is **keyword search only** (SQLite FTS5). The vector half and the fusion that ranks them together live in `core/brain/src/hybrid_retriever.rs` and are exercised by the test suite, but they need the embedder, which this read-only CLI does not load. So what you see below is the lexical half doing its job, not the full recall path.

```console
$ mci-brain stats
Events: 20
Oldest: 2026-08-02T20:32:59.612Z (1785702779612697)
Newest: 2026-08-02T22:26:59.612Z (1785709619612697)
Entities: 0
```

Ask for something by an exact term:

```console
$ mci-brain search "ScreenCaptureKit"
event:6 | 2026-08-02T21:02:38.651Z | com.mci.demo.seed.safari
  | ScreenCaptureKit | Apple Developer Documentation
  | https://developer.apple.com/documentation/screencapturekit
  | SCStream delivers frames via SCStreamOutput. The MCI helper uses the
    SCStream path on macOS 14+; cascade runs synchronously in the callback.
```

Note what came back with it: the app, the window title, the URL, and the moment. That context is the point. A filename would not have helped you.

Pull one moment up in full:

```console
$ mci-brain show 6
Event: event:6
Timestamp: 2026-08-02T21:01:34.593Z (1785704494593762)
App: com.mci.demo.seed.safari
Window: ScreenCaptureKit | Apple Developer Documentation
URL: https://developer.apple.com/documentation/screencapturekit
Text:
SCStream delivers frames via SCStreamOutput. The MCI helper uses the SCStream
path on macOS 14+; cascade runs synchronously in the callback.
```

Or take the whole thing with you. It is your file:

```console
$ mci-brain export --format jsonl | head -1
{"app_bundle_id":"com.mci.demo.seed.safari","cascade_reason":0,"event_id":1, ...}
```

---

## Turning on semantic recall

Two commands. This whole path has been run end to end on a clean machine.

**1. Build the model.** ArcticEmbedS as Core ML. About 66 MB, so it is not in the repo. Needs Python 3.11 or 3.12 (not 3.14, coremltools does not support it yet) and roughly 2 GB of disk for torch:

```bash
python3.11 -m venv .venv-ml && source .venv-ml/bin/activate
pip install -r scripts/requirements-ml.txt
python scripts/convert_embedder.py \
  --output models/ArcticEmbedS_INT8.mlpackage --verify
```

That writes two things: a `.mlpackage` and a compiled `.mlmodelc` beside it. **The `.mlmodelc` is the one that matters.** A raw `.mlpackage` cannot be opened at runtime; Core ML rejects it with "Compile the model with Xcode." The script now compiles it for you, which it did not always do, and that gap was invisible because the loader treats a failed load and a missing file identically.

**2. Fill in the vectors.** Events are stored without embeddings, so something has to go back over them:

```bash
mci-agent embed-backfill
mci-agent embed-backfill --batch-size 64
```

Idempotent, so running it twice is a no-op rather than an error. It refuses to run without a working model instead of writing zero vectors, because a zero vector matches every query equally and would look like a ranking bug rather than a missing model.

Then restart `mcp-serve`. It picks the mode once at startup, and the line should now read:

```
recall=hybrid (FTS5 + semantic, ADR-0010 min-max CC)
```

If the model lives somewhere else, point at it:

```bash
export MCI_ARCTIC_MODEL_PATH=models/ArcticEmbedS_INT8.mlmodelc
```

### Does it actually help?

Here is the same query against the same 20-event demo brain, once with keyword search and once with hybrid. None of the words in the query appear anywhere in the corpus:

```console
$ mci_recall "finding things by meaning rather than exact wording"

# lexical-only
0 hits

# hybrid
3 hits
  score=0.645  Notion — MCI / Recall UI Spec
  score=0.598  Snowflake Arctic Embed S — Hugging Face
  score=0.594  sqlite-vec — A vector search SQLite extension
```

Keyword search cannot answer that question, because you did not use any of the words. That difference is the entire reason this project exists.

### On the Neural Engine message

You will see this during conversion, and it is not a problem:

```
MILCompilerForANE error: failed to compile ANE model using ANEF.
Error=_ANECompiler : ANECCompile() FAILED.
```

There is no Neural Engine residency for this BERT graph. It cannot run on the ANE, so Core ML tries, fails, and moves on. The Rust loader never goes down that path anyway: it pins compute units to CPU on purpose, which is a measured decision rather than a default. The rationale is written up in `adapters/macos/mci-embed-coreml/src/lib.rs` under the E5RT story, and it is worth reading if you are tempted to change it.

Measured here, Apple Silicon, CPU-only pin:

| | |
|---|---|
| Model load | ~340 ms, once at startup |
| Per embed | ~18 ms |

Embedding happens on an idle loop, not in front of your query, so 18 ms is not a number anyone will feel. CPU+GPU benchmarks faster (~1.9 ms in the notes in that file) and would be the thing to reach for if the embedder ever moved onto a hot path. It has not, so it stays on CPU.

### How I know the vectors are right

Loading is not the same as working. `adapters/macos/mci-embed-coreml/tests/quality.rs` embeds 50 fixture sentences through the Core ML model and compares each one against a Python FP32 reference generated from the original Hugging Face weights. The bar is cosine `>= 0.999` on every sentence.

```bash
python scripts/convert_embedder.py \
  --output models/ArcticEmbedS_INT8.mlpackage --verify --fixtures
cargo test -p mci-embed-coreml --test quality
```

```
test cosine_similarity_matches_python_reference ... ok
test output_is_l2_normalized ... ok
test output_dimension_is_384 ... ok
test empty_string_returns_valid_vector ... ok
test truncation_long_input_does_not_crash ... ok
```

That test used to skip silently, because it needs a fixture file that was never committed. It runs now.

## Pulling in your other MCP servers

The other direction. The MCP server lets an agent ask Hippocampus what you saw. Here, Hippocampus asks your other MCP servers what they have and keeps it, so a search covers your screen and your connectors at once.

```bash
mci-agent mcp-sync
```

One pass over every server you registered, then it exits. Nothing runs in the background.

Servers are registered in a file, one block each:

```
~/Library/Application Support/MCI/mcp-servers.toml
```

```toml
[[server]]
name = "my-server"                       # required, unique, [a-zA-Z0-9_-]
url  = "http://127.0.0.1:7890/mcp"       # required, must be loopback
# auth_header = "Bearer sk-..."          # optional, sent as Authorization
# enabled = true                         # optional, defaults to true
```

The file has to be mode 0600 and owned by you, or it is refused rather than read, because `auth_header` can hold a real token:

```bash
mkdir -p ~/Library/Application\ Support/MCI
touch ~/Library/Application\ Support/MCI/mcp-servers.toml
chmod 600 ~/Library/Application\ Support/MCI/mcp-servers.toml
```

If the file does not exist, `mcp-sync` says so, prints the block above, and exits zero. Having no MCP servers is a normal state, not an error.

Four things worth knowing about what it stores:

- **The url must be loopback**, 127.0.0.1 or localhost. This project has no outbound network path and is not getting one to fetch your Notion pages. Run the server on your own machine.
- **Every event it writes is tagged `mcp:<name>`** in `app_bundle_id`, so you can always tell a memory came from a connector rather than from your screen. `mci_events_by_app` scopes to it.
- **Small resources are stored whole; large ones are stored as a pointer.** Anything over 512 KB becomes a `[CATALOG_ONLY ...]` row carrying the URI and metadata and none of the body. A 100 MB page should not quietly become 100 MB of brain.
- **Re-running is a no-op.** A resource already ingested is not fetched or written a second time, so this is safe in a cron.

The report is counts, not prose:

```
mci-agent mcp-sync: done. 1 server(s) contacted, 0 failed to connect,
2 resource(s) discovered, 2 materialized, 0 cataloged, 2 event(s) written.
```

`event(s) written` is measured against the store before and after, so a second run says `0` rather than repeating the first run's number.

**What I have and have not run.** The whole path is exercised end to end in `apps/agent/tests/mcp_sync.rs` against a local MCP server: registration, connect, read, write, tagging, the size split, and a re-run writing nothing. I have not pointed it at a third-party MCP server, so I cannot tell you how any particular one behaves.

---

## Prerequisites

| Requirement | Minimum | Check | Install |
|---|---|---|---|
| macOS | 14 (Sonoma) | `sw_vers -productVersion` | Apple Silicon. The macOS-only crates are `cfg`-gated so the CLI should build elsewhere, but I have only run this on macOS |
| Rust | 1.83 | `rustc --version` | [rustup.rs](https://rustup.rs) |
| Xcode | 15+ | `xcodebuild -version` | Only needed for the Swift app, not the CLI |
| openssl | any | `openssl version` | Ships with macOS |

The one-minute demo needs only Rust and openssl. Xcode is for building the menu-bar app.

---

## Commands

Every command reads the brain at `$MCI_DB_PATH` using the key in `$MCI_DB_KEY_HEX`, or, if that is unset, the `dev.key` file that `mci-agent init` writes to `~/Library/Application Support/MCI/`. `mci-brain` opens the database read-only at the SQLite driver level, so it cannot corrupt or modify your brain no matter what you type.

```bash
mci-brain stats                          # counts and time range
mci-brain stats --json                   # same, machine-readable

mci-brain search "sqlite-vec"            # find events by text
mci-brain search "vector" --limit 20
mci-brain search "..." --json

mci-brain show 6                         # one event in full
mci-brain recent --limit 5               # newest first

mci-brain export --format jsonl          # take everything with you
mci-brain export --format csv --out brain.csv
mci-brain export --since 1785702779612697
```

The agent-facing side lives on `mci-agent`:

```bash
mci-agent init                           # key + import Claude Code history + index + register
mci-agent doctor                         # say why the brain is empty and what to fix
mci-agent import-sessions                # import Claude Code transcripts (text blocks only)
mci-agent enrich                         # entities, embeddings, episodes, identity links
mci-agent brief --date 2026-10-07        # draft a daily brief (needs the Qwen3 model)
mci-agent mcp-serve                      # MCP server over stdio
mci-agent register-mcp                   # add it to Claude Code
mci-agent mcp-sync                       # pull from your registered MCP servers
mci-agent embed-backfill                 # fill in missing vectors
mci-agent embed-backfill --batch-size 64
mci-agent stats --source safari
```

`init`, `import-sessions`, `enrich`, `embed-backfill`, `brief` and `mcp-sync` write to the brain. Everything else reads. Each takes `--db-path` and falls back to `$MCI_DB_PATH`.

| Variable | What it does | Required |
|---|---|---|
| `MCI_DB_KEY_HEX` | 64-character hex SQLCipher key | No, if `dev.key` exists (`mci-agent init` writes it) |
| `MCI_DB_PATH` | Path to the brain file | No, defaults to `~/Library/Application Support/MCI/mci.sqlite` |
| `MCI_EMBEDDER_DISABLED` | `1` forces keyword-only recall in `mcp-serve` | No |
| `MCI_BRIEFS_DISABLED` | `1` switches daily briefs off | No |
| `HIPPOCAMPUS_ENABLE_V2P1` | Turns live capture on | No, and leave it off until capture is verified |

---

## Troubleshooting

Start with `mci-agent doctor`. It opens the brain read-only and says why it is empty, or what is blocking, in plain words.

**`cargo: command not found`**. Install Rust from [rustup.rs](https://rustup.rs), then open a new terminal so `~/.cargo/bin` is on your PATH.

**`try-it.sh` fails on the build step**. The first build compiles the whole workspace and needs a few minutes. If it fails outright, run `cargo build -p mci-agent --bins` on its own to see the real error.

**`MCI_DB_KEY_HEX` errors**. The key must be exactly 64 hex characters (32 bytes). Generate one with `openssl rand -hex 32`. A wrong key does not produce a helpful error, it produces a file that will not open, because that is what encryption means.

**Search returns nothing**. Check `mci-brain stats` first. If it says `Events: 0`, the brain is empty and the seeder did not run. If there are events, your term is probably not in them; the demo corpus is about screen-capture and SQLite topics, so try `sqlite`, `embedding`, or `ScreenCaptureKit`.

**I want my demo brain gone**. `rm -rf ./hippocampus-demo`. The key lives only in that folder, so deleting it makes the data unrecoverable.

**The app will not open**. It is not notarized under my own Apple Developer ID yet. Right-click the app and choose Open, or allow it in System Settings under Privacy and Security.
