<h1 align="center">Hippocampus</h1>

<p align="center"><strong>Your computer already sees everything you do. It just doesn't remember any of it.</strong></p>

<p align="center">
  <a href="#try-it-in-about-a-minute">Try it</a> ·
  <a href="#see-it-work">See it work</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#what-works-and-what-doesnt">Honest status</a> ·
  <a href="#how-this-compares">Compared to mem0 and supermemory</a>
</p>

---

Hippocampus is a Mac app that remembers what was on your screen, so you can ask for it later in plain language.

Not "what file was that in." **"That pricing page I looked at last Tuesday, when I was annoyed."** You remember situations. Your computer remembers filenames. This closes that gap.

It runs entirely on your machine. There is no server to trust, because there is no server.

- **Local by construction, not by policy.** Screen text is parsed on-device, embedded on the Neural Engine, and written to one encrypted SQLite file. No API key is needed and nothing is sent anywhere.
- **One file, one lock.** Everything (rows, full-text index, vectors) lives inside a single SQLCipher database. Deleting a memory crypto-shreds it.
- **Search the way you remember.** Keyword search for exact things like an error code, vector search for vague things like "that pricing discussion," fused into one ranked list. (The engine does both; the CLI below exposes the keyword half. See [what works](#what-works-and-what-doesnt).)
- **Blocked at the source.** Password prompts, private browsing, and DRM video are refused before a frame is ever encoded, not scrubbed afterwards.

---

## Try it in about a minute

You do not need to install the app, grant screen permissions, or trust me with anything. This builds the CLI, makes a throwaway encrypted brain in a sandbox folder, fills it with 20 fake events, and searches it.

```bash
git clone https://github.com/amyjainberkeley/hippocampus.git
cd hippocampus
./scripts/try-it.sh
```

Everything lands in `./hippocampus-demo/`. Your real brain is never touched, no capture runs, nothing reads your screen, and nothing goes over the network. When you are done:

```bash
rm -rf ./hippocampus-demo
```

That deletes the database and its only key, which makes the data unrecoverable. That is the same crypto-shred property the real store has.

---

## See it work

Real output from the script above, not a mockup.

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

## How it works

Five steps. The interesting one is step 1.

```mermaid
flowchart LR
    A["Screen<br/>+ app, window, URL"] --> B["Watch<br/>drop 99% of frames"]
    B --> C["Read<br/>on-device OCR"]
    C --> D["Understand<br/>group + embed<br/>(idle time only)"]
    D --> E[("One encrypted<br/>SQLite file")]
    E --> F["Recall<br/>keyword + vector<br/>fused"]
    F --> G["You, or an agent<br/>acting for you"]
```

**1. Watch.** A small Swift helper grabs the screen only when something meaningful changes, never on a timer. An idle detector stops it when you walk away, and a perceptual hash throws away frames that are near-copies of the last one.

This step is most of the engineering. A day of screen recording is millions of frames and almost none of them matter. The filter chain is what turns eight hours into a few thousand moments instead of a few million images. Get it wrong and you have a hot laptop and a useless database.

**2. Read.** Surviving frames go through on-device OCR and get joined to what you were doing: which app, which window, which URL.

**3. Understand.** Moments get grouped into episodes and turned into vectors by a small embedding model on the Neural Engine. This happens when your machine is idle, never while you are using it.

**4. Store.** Everything goes into one encrypted SQLite file. The key is wrapped by the Secure Enclave and cannot be exported.

**5. Recall.** Your question runs two searches at once, keyword and vector, and the results are merged and weighted by how recent and how relevant each hit is.

### The one decision that shapes everything else

Screen capture has to be written per operating system. Encryption, search, and ranking do not.

So there is exactly one seam: a Rust trait called `CaptureSource`. Below it, a thin native adapter that talks to macOS. Above it, everything else in Rust, with no OS-specific code allowed.

```
┌─────────────────────────┐
│  Swift capture helper   │   macOS only. Frames, OCR, window context.
└───────────┬─────────────┘
            │  CaptureSource  ← the only seam
┌───────────▼─────────────┐
│  Rust core + brain      │   Written once. Filter chain, embeddings,
│                         │   encryption, search, ranking.
└─────────────────────────┘
```

Adding Windows later means writing one adapter, not writing the brain a second time. The other rule: pixels never cross that seam as a copy. The adapter hands over a borrowed handle to memory the GPU already owns. Copying every frame is the difference between a program you forget is running and a fan that never stops.

Longer version in [ARCHITECTURE.md](ARCHITECTURE.md), and the arguments I had with myself are in the 37 records under [docs/decisions/](docs/decisions/).

---

## What works and what doesn't

Most projects bury this. It should be near the top, because it decides whether the rest of the README is worth your time.

| Piece | State |
|---|---|
| **Encrypted store + keyword search** | **Works, tested.** This is what `try-it.sh` exercises end to end. |
| **Vector search + fusion ranking** | **Works, tested, but not in the CLI.** `hybrid_retriever.rs` fuses keyword and vector hits and weights them by recency. It is covered by the test suite and used by the app, but the read-only CLI does not load the embedder, so the demo does not show it. |
| **On-device embeddings** | **Works.** Runs through Core ML with a regression test asserting the vectors still match a known-good reference. |
| **Pulling text apart** | **Works.** Names, dates, URLs, and the things that should never be stored at all, like a one-time code. |
| **Reading Mail and Messages** | **Read-only.** Nothing is written to the brain until the per-source redaction path is finished. |
| **Live screen capture** | **Built, unproven, ships OFF.** All the code exists. I have not watched it run all day on a real machine and measured it, so I am not going to tell you it works. |
| **Sync between machines** | **Skeleton.** The crypto is there. Proof that two devices converge is not. |
| **Windows** | **Not started.** An empty crate with the right shape. |

The test suite is 535 tests on the core (`cargo test -p mci-brain`). The build is not signed or notarized under my own Apple Developer ID yet, so a build you make yourself needs to be allowed through Gatekeeper by hand.

If you only take one thing from this table: **capture is off by default and unverified.** Everything you can try today is the recall half.

---

## How this compares

The obvious question is how this differs from [mem0](https://github.com/mem0ai/mem0) (62k stars) and [supermemory](https://github.com/supermemoryai/supermemory) (29k stars). They are good and they are more mature. They also solve a different problem.

**They remember what you tell them. This remembers what you saw.**

mem0 and supermemory are memory layers for agents. You hand them a conversation, a document, or a fact, and they store and retrieve it. The input is text you deliberately give them.

Hippocampus has no input step. The source is your screen, which means it reaches the context you would never think to write down: the paper you skimmed, the tab you closed, the number in a dashboard you glanced at once.

| | mem0 | supermemory | Hippocampus |
|---|---|---|---|
| What goes in | Conversations, facts you pass it | Documents, files, connectors | Your screen, automatically |
| Runs offline | Yes, library mode | Yes, local binary | Yes, and there is no cloud mode |
| Retrieval | Vector, plus a graph store | Embedded graph engine | Keyword + vector fused, inside SQLite |
| Where memories live | Your DB or their cloud | Your machine or their cloud | One encrypted file, only your machine |
| Maturity | Production, 62k stars | Production, 29k stars | Recall works; capture unproven |

**On benchmarks, plainly: I have not run any.** mem0 publishes LoCoMo and LongMemEval numbers, supermemory publishes theirs. Those are conversational-memory benchmarks, and Hippocampus has no conversational input, so the numbers would not be comparable even if I ran them. I would rather say that than put a table of favorable numbers next to theirs. If you want a memory layer for an agent today, use one of theirs. Use this if you want your own machine to remember what you saw.

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

Every command reads the brain at `$MCI_DB_PATH` using the key in `$MCI_DB_KEY_HEX`. The CLI opens the database read-only at the SQLite driver level, so it cannot corrupt or modify your brain no matter what you type.

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

| Variable | What it does | Required |
|---|---|---|
| `MCI_DB_KEY_HEX` | 64-character hex SQLCipher key | Yes |
| `MCI_DB_PATH` | Path to the brain file | No, defaults to `~/Library/Application Support/MCI/mci.sqlite` |
| `HIPPOCAMPUS_ENABLE_V2P1` | Turns live capture on | No, and leave it off until capture is verified |

---

## Privacy, concretely

The promise is "nothing leaves your machine," so here is what enforces it rather than my word for it.

- **One encrypted SQLite file** via SQLCipher. The key is wrapped by a Keychain item gated on the Secure Enclave and cannot be exported.
- **No vector database outside that file.** This is why search uses sqlite-vec, which lives inside the same file, rather than something faster and separate. A second store would mean a second encryption boundary, and the weaker one would be the real one.
- **Blocked at the source, not scrubbed after.** Password prompts, private browsing, and DRM surfaces are refused before a frame is encoded. Scrubbing afterwards means the data existed.
- **A second layer for text.** Extracted text is checked for one-time codes, bank alerts, and API keys and refused. Tested against a synthetic corpus of 133 message shapes built from public security writeups, NIST guidance, and OWASP fixtures, in [core/brain/fixtures/](core/brain/fixtures/). Those fixtures contain no real messages.
- **Delete means delete.** Removing a memory crypto-shreds it rather than hiding a row.
- **No telemetry.** No analytics, no usage tracking, no crash reporting to me.

Found something wrong? [SECURITY.md](SECURITY.md) says what I most want to hear about and how to report it privately.

---

## Layout

| Where | What |
|---|---|
| `core/brain/` | The interesting part. Search, ranking, episode grouping, embeddings, entity extraction, redaction. |
| `core/` | The portable core. The capture seam, encryption, the SQLite store, IPC. |
| `adapters/macos/` | Swift. Screen capture, OCR, hardware encode, Mail and Messages readers. |
| `apps/` | The menu-bar app, the recall window, onboarding, the agent bridge. |
| `docs/decisions/` | 37 records of why things are the way they are. |
| `scripts/try-it.sh` | The one-minute demo. |

```bash
cargo test -p mci-brain      # the core: 535 tests
cargo test --workspace       # everything
```

---

## Troubleshooting

**`cargo: command not found`**. Install Rust from [rustup.rs](https://rustup.rs), then open a new terminal so `~/.cargo/bin` is on your PATH.

**`try-it.sh` fails on the build step**. The first build compiles the whole workspace and needs a few minutes. If it fails outright, run `cargo build -p mci-agent --bins` on its own to see the real error.

**`MCI_DB_KEY_HEX` errors**. The key must be exactly 64 hex characters (32 bytes). Generate one with `openssl rand -hex 32`. A wrong key does not produce a helpful error, it produces a file that will not open, because that is what encryption means.

**Search returns nothing**. Check `mci-brain stats` first. If it says `Events: 0`, the brain is empty and the seeder did not run. If there are events, your term is probably not in them; the demo corpus is about screen-capture and SQLite topics, so try `sqlite`, `embedding`, or `ScreenCaptureKit`.

**I want my demo brain gone**. `rm -rf ./hippocampus-demo`. The key lives only in that folder, so deleting it makes the data unrecoverable.

**The app will not open**. It is not notarized under my own Apple Developer ID yet. Right-click the app and choose Open, or allow it in System Settings under Privacy and Security.

---

## Contributing

The most useful thing right now is not a pull request. It is telling me where this README lost you, or where a command did something other than what it said. Open an issue.

If you want to write code, `core/brain/` is the part with the most surface area and the best test coverage to work against. Read [ARCHITECTURE.md](ARCHITECTURE.md) first, especially the invariants at the bottom. There are four and breaking any of them breaks the product.

## License

Apache 2.0. See [LICENSE](LICENSE).
