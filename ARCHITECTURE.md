# Architecture

Hippocampus reads what is on a Mac's screen, keeps it in an encrypted database on that Mac, learns from it what the person works on, and lets them and their AI tools search it. This page is the map: the processes, how a moment travels from the screen to an answer, and the rules a change must keep. What works today, and how each part was checked, is in [docs/STATUS.md](docs/STATUS.md). Why things are the way they are is in [docs/decisions/](docs/decisions/).

Everything runs on the Mac. There is no server, no account and no sync between Macs.

## The processes

Hippocampus.app holds eight programs. The menu-bar app starts and stops the rest.

| Process | Language, source | What it does |
| --- | --- | --- |
| `Hippocampus` | Swift, [`apps/hippocampus`](apps/hippocampus) | The menu bar, Ask, Preferences and the updater. Starts the helper and the agent, and stops everything it started on Quit. |
| `MCICaptureHelper` | Swift, [`adapters/macos/MCICaptureHelper`](adapters/macos/MCICaptureHelper) | Captures the screen with ScreenCaptureKit, decides what may be read, has it read, and sends the text to the agent. Keeps screenshots of the window in front, encrypted. |
| `hippocampus-ocr` | Python, frozen, [`tools/ocr`](tools/ocr) | The text reader: RapidOCR with the PaddleOCR PP-OCRv6 small models on ONNX Runtime. A warm child of the helper, in `Contents/Resources/HippocampusOCR`. |
| `mci-agent` | Rust, [`apps/agent`](apps/agent) | Owns the memory. Stores what the helper sends, builds search data, works out sessions and what it learns about the person, deletes what is past its keep date, and serves memory to AI tools (`mci-agent mcp-serve`). |
| `hippocampus-mind` | Swift, [`apps/mind`](apps/mind) | Writes answers, session notes, the day's summary and what is learned, with Apple Intelligence or a model server on the Mac. A child of the agent; it gets only `PATH` and `HOME`. |
| `recall-ui` | Swift, [`apps/recall-ui`](apps/recall-ui) | The window: Overview, Ask with its History, You, and the privacy window. Reads memory through [`mci-brain-ffi`](adapters/macos/mci-brain-ffi). |
| `onboarding` | Swift, [`apps/onboarding`](apps/onboarding) | Setup's four screens, the two permissions, and Choose Apps. |
| `hippocampus-native-host` | Rust, [`apps/hippocampus-native-host`](apps/hippocampus-native-host) | Passes page text from the optional browser extension ([`extensions/`](extensions)) to the agent. |

## From the screen to an answer

```
 ScreenCaptureKit                         MCICaptureHelper                                   mci-agent
┌──────────────────────┐   pixels   ┌─────────────────────────────────┐   framed text   ┌──────────────────────────────┐
│ the window in front  │ ─────────▶ │ skip rules, then the reader     │ ──────────────▶ │ encrypted store (SQLCipher)  │
│ every display        │            │ (hippocampus-ocr), secret scans │   over a pipe    │ search data, sessions,       │
└──────────────────────┘            │ reading order, screenshot (AES) │                  │ what it learns, retention    │
                                    └─────────────────────────────────┘                  └──────┬───────────┬──────────┘
                                                                                                │           │ JSON lines
                                                                 Ask, the window, AI tools ◀────┘           ▼
                                                                 (mcp-serve, mci-brain-ffi)         hippocampus-mind
```

1. **Capture.** The helper runs two kinds of ScreenCaptureKit stream. One follows the window in front, at up to two frames a second. One per display covers everything else, at one frame every two seconds. Hippocampus's own windows, the skipped apps, notification banners and the Dock are filtered out of the display streams before any pixel exists ([ADR-0040](docs/decisions/0040-whole-screen-background-capture.md)).
2. **Decide.** Before a frame is read, the suppression cascade checks it: a skipped app, a private browser window, a sign-in or bank site, a blacked-out region, an active password field ([`SuppressionCascade.swift`](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift), [ADR-0013](docs/decisions/0013-native-grade-sensitive-surface-suppression.md)). A frame that fails any check is not read.
3. **Pace.** A frame is read only when its text changed. The window in front is read at most every 3 seconds; the displays at most every 30 seconds plugged in, 60 on battery, and not in Low Power Mode. After each read the reader rests three times as long as the read took, more on battery ([ADR-0041](docs/decisions/0041-browsers-and-reading-cadence.md)).
4. **Read.** The worker returns lines with their boxes and the pane separators it finds. The helper puts the lines in reading order and sets the window's tabs, sidebars and bars apart from what was being read. It checks the text against four secret patterns three times, as read, in reading order and exactly as it will be stored, and drops the moment if any matches. The reader's choice, and its measured accuracy and cost, are in the [bake-off](eval/ocr-bakeoff-2026-10-15.md).
5. **Store.** The helper sends each moment over a pipe to `mci-agent --drain-stdin`, in the framed wire format of [`core/src/ipc`](core/src/ipc). Text from other windows is stored under its own app and title. The agent writes it to one SQLCipher database, `~/Library/Application Support/MCI/mci.sqlite`. Screenshots are JPEGs sealed with AES-GCM in `MCI/blobs/`.
6. **Index.** In the background the agent embeds new moments with Snowflake Arctic Embed S on Core ML (384 dimensions, run on the CPU) and indexes their text with FTS5. A search mixes the two scores with recency and source ([ADR-0010](docs/decisions/0010-event-episode-retrieval-unit-cc-fusion.md)).
7. **Learn.** Every cycle the agent splits recent activity into sessions, writes a note for each, and folds what the notes say about the person into short statements with the moments behind them. The method follows Shaikh et al. (2025), who call it a general user model; Hippocampus keeps the result as a personal context model: plain statements, each linked to its evidence, in the words AI tools receive ([`apps/agent/src/understanding`](apps/agent/src/understanding)). The writing is done by `hippocampus-mind`. Without a model, sessions and the day are written from measurements alone, and nothing new is learned.
8. **Answer.** Ask, in the menu-bar app, keeps two `mci-agent mcp-serve` processes warm: one searches, the other answers through `hippocampus-mind`, with this window as the first source. The window reads the same memory through `mci-brain-ffi`.

## AI tools

Connect AI Tools… registers `mci-agent mcp-serve` as an MCP server named `hippocampus` in Claude Code (`~/.claude.json`) and Codex (`~/.codex/config.toml`). The server speaks JSON-RPC over stdio, opens no port, and is read-only: `mci_recall`, `mci_events_since`, `mci_stats`, `mci_episodes`, `mci_events_by_app`, `mci_context`, `mci_day`, `mci_searches`, `mci_user_model` and `mci_sessions` ([`apps/agent/src/mcp`](apps/agent/src/mcp)). Ask's own session adds `mci_ask` and `mci_suggest`.

If the person agrees, a session-start hook (`mci-agent handoff --format claude-hook`) gives each new Claude Code session up to four lines of recent work and up to six things learned about the person, with sources; Codex is told to ask for the same ([`SessionContextInstaller.swift`](apps/hippocampus/Sources/HippocampusKit/SessionContextInstaller.swift)). The tool starts its own `mcp-serve`, which reads the key from the Keychain, so it can read memory while Hippocampus is quit.

## Models

| Model | Where | Used for |
| --- | --- | --- |
| PaddleOCR PP-OCRv6 small, through RapidOCR | Bundled in the OCR worker | Reading the screen |
| Snowflake Arctic Embed S, FP16 Core ML | Bundled in the app | Search by meaning |
| Apple Intelligence (Foundation Models) | macOS 26, on the Mac | Answers, notes, the day, what is learned |
| A model on Ollama or LM Studio | The person's own server at 127.0.0.1, ::1 or localhost | The same, when Apple Intelligence isn't there |

`hippocampus-mind` links Foundation Models weakly, so it is built to start on macOS 14 and 15, where it reports answers as unavailable unless a model server is running. Background writing with a model server waits for mains power; answers to Ask don't.

## Keys and encryption

The database key is a generic-password item in the login Keychain, not synced, with an access list of Hippocampus's own signed programs ([`adapters/macos/mci-keychain`](adapters/macos/mci-keychain)). Child processes and AI tools get a Keychain reference, never the key. Screenshots are sealed with a key derived from it. A Developer ID signature that stays the same across updates keeps the Keychain's access list valid; an ad-hoc development build can't show that. [PRIVACY.md](PRIVACY.md#threat-model) says what this protects against and what it doesn't.

## Optional paths, off by default

- **Mail and Messages.** With "Capture + Deep hook" chosen in Choose Apps and Full Disk Access granted, the agent reads new messages from `chat.db` and Mail's files ([`mci-messages-reader`](adapters/macos/mci-messages-reader), [`mci-mail-reader`](adapters/macos/mci-mail-reader)). One-time codes, bank alerts and mail from banks are taken out before anything is stored.
- **The browser extension.** A Chromium extension, from source in [`extensions/chromium`](extensions/chromium), sends each page's address and the text not on screen through the native host to a Unix socket in the data folder. The Safari extension is a scaffold.
- **Your own MCP servers.** `mci-agent mcp-sync` reads from servers listed in `mcp-servers.toml`, at addresses on this Mac only.
- **Transcripts.** `mci-agent init` and `import-sessions` import Claude Code and Codex transcripts. The app never does.

## Not built

- Sync between Macs. Earlier server and sync code was removed, and nothing sends memory anywhere.
- Windows. [`adapters/windows`](adapters/windows) is a scaffold of the `CaptureSource` trait in [`core/src/capture.rs`](core/src/capture.rs); the macOS helper speaks the wire format directly.
- Calendar, Notes and Reminders readers: scaffolds that return nothing.

## Code map

| Path | What is there |
| --- | --- |
| `core/` (`mci-core`) | The wire format between helper and agent, the `CaptureSource` trait, and key handling. No macOS code. |
| `core/brain/` (`mci-brain`) | The encrypted store, search, sessions, what is learned, deletion and retention, redaction and entity extraction. No macOS code. |
| `core/brief/`, `core/brief-eval/` | Daily briefs, written from the day's moments with citations, and their scoring harness. |
| `core/mcp-client/` | The client `mcp-sync` uses for the person's own MCP servers. |
| `adapters/macos/` | The capture helper, the screenshot codec, the Keychain, Core ML, the window's FFI, and the Mail and Messages readers. |
| `apps/` | The programs in the table above. |
| `tools/ocr/` | The OCR worker, its build (`prepare.py`, `bundle.py`), and the reading bench in `screens/`. |
| `eval/`, `docs/eval/` | Evaluations: the reader bake-off, search, briefs and handoff. |
| `scripts/` | Builds, the release, and `check.sh`, which runs every test lane. |

## Rules a change must keep

- **Read nothing before the skip rules run.** The cascade decides before any read, and the secret checks run before text leaves the helper. They may be extended, never weakened, and their tests must pass.
- **One encrypted database.** Nothing the person saw is stored outside SQLCipher and the sealed screenshots.
- **No macOS code in `core/`.** It stays portable, so a second platform means a new adapter.
- **Nothing leaves without the person's choice.** No network path carries what was on screen, except to the AI tools and the model server on this Mac the person chose. A change to that is a new decision record.
- **Errors surface.** Nothing falls back silently to a worse answer.
