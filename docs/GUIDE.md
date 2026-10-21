# Hippocampus guide

The [README](../README.md) says what Hippocampus is. This is the reference: the window's keys, the command line, a made-up memory to try things on, Demo Memory, your calendar, pictures of other windows, search by meaning in a source build, keeping an app out, your own MCP servers, and fixing things.

- [The window's keys](#the-windows-keys)
- [The command line](#the-command-line)
- [Try it on a made-up memory](#try-it-on-a-made-up-memory)
- [Demo Memory](#demo-memory)
- [Your calendar](#your-calendar)
- [Pictures of other windows](#pictures-of-other-windows)
- [Search by meaning in a source build](#search-by-meaning-in-a-source-build)
- [Keep an app out](#keep-an-app-out)
- [Pull in your other MCP servers](#pull-in-your-other-mcp-servers)
- [Settings without a switch](#settings-without-a-switch)
- [Build requirements](#build-requirements)
- [Uninstall](#uninstall)
- [Troubleshooting](#troubleshooting)

## The window's keys

| Key | Does |
| --- | --- |
| ⌘1 to ⌘9 | Today, History, Web Pages, Documents, Code, Conversations, Looked Up, About You, AI Tools. Privacy opens from its row and the hi mark's menu. |
| ⌘F | The field, kept to the page you're on. |
| ⌘N | A new question: the field emptied, searching everything. |
| ⌘K | The command bar: places, Working On items and actions. |
| ⌘[ and ⌘] | Back and Forward. |
| ⌘T | Today's date on Today and History; elsewhere, Today. |
| ⌘← and ⌘→ | The day before or after, on Today and History. |
| ⌘↩ | Ask your AI tool with what you picked, or with the question in the field. |
| ⌥↩ | Ask on this Mac. |
| ⇧⌘C | Copy for Your AI. |
| Space | The picked moment's screenshot. |
| ⌘⌫ | Forget what you picked; ⌘Z undoes it while its note shows. |
| ⇧⌘⌫ | Forget Recent…: the last 10 minutes, the last hour or today. |
| ⌃⌘S | Show or hide the sidebar. |
| ⌘/ | Every key, in one sheet. |

Ask, from any app, opens with Shift twice; Preferences offers Fn (Globe), right Shift, right ⌘ or right ⌥ instead. In Ask, ↩ opens, ⌘↩ asks your AI tool and ⌥↩ resumes a project.

## The command line

The one-line installer and the Homebrew cask put `mci-agent` on your PATH. It reads the same memory as the app, with the key from your Keychain. `mci-agent --help` lists every command; these are the useful ones.

| Command | What it does |
| --- | --- |
| `mci-agent doctor` | Says why memory is empty, or what is in the way, in plain words. Reads only. |
| `mci-agent context --focus "a task"` | Prints a short summary of what memory holds about a task, with the moments it comes from. |
| `mci-agent overview --date 2026-10-15 --json` | The day as Today draws it. Reads only. |
| `mci-agent work --json` | Working On: projects and documents by name, the pages read, and which moments belong to each. Reads only. |
| `mci-agent clients --json` | What each AI tool can reach, with no content. `--disconnect claude-code`, `codex` or `all` takes Hippocampus out of a tool's settings, as Preferences' Disconnect does. |
| `mci-agent mcp-serve` | The MCP server an AI tool starts. It speaks over stdio and opens no port. |
| `mci-agent register-clients` | Adds that server to Claude Code and Codex, as Connect AI Tools… does. |
| `mci-agent embed-backfill` | Builds search-by-meaning data for moments that have none. Needs the embedding model. |
| `mci-agent mcp-sync` | Reads once from your own MCP servers ([below](#pull-in-your-other-mcp-servers)). |
| `mci-agent import-sessions` | Imports your Claude Code and Codex transcripts from `~/.claude/projects` and `~/.codex/sessions`. The app never does this by itself. |

Commands that write to memory (`import-sessions`, `embed-backfill`, `mcp-sync`, `enrich`, `brief`) refuse to run while another program holds the database's one writer lease. While Hippocampus is remembering, its own agent holds it, so quit Hippocampus first.

`mci-agent init` and `mci-agent connect --all` are the older command-line setup. Besides registering the MCP server, they add session-start hooks and load a background job (`ai.hippocampus.refresh`) that imports your Claude Code and Codex transcripts; `init` also imports them at once. The app doesn't need them. `mci-agent disconnect --all` removes the hooks, the MCP registrations and the refresh job, like Disconnect All… in Preferences ([more](../PRIVACY.md#disconnecting-an-ai-tool)).

## Try it on a made-up memory

```bash
./scripts/try-it.sh
```

It builds the command line, makes a throwaway encrypted memory in `./hippocampus-demo` with its own key, adds 20 made-up moments and searches them. It needs Rust and openssl, and no permissions. It doesn't open your real memory or ask your Keychain for its key.

The demo uses `mci-brain`, a read-only command for inspecting a memory file. It comes with a source build, not with the app. This is real output from a run on October 16, 2026:

```console
$ mci-brain stats
Events: 20
Oldest: 2026-10-16T06:19:21.353Z (1792131561353945)
Newest: 2026-10-16T08:13:21.353Z (1792138401353945)
Entities: 0
Entity mentions: 0
Identities: 0
Episode links: 0

$ mci-brain show 12
Event: event:12
Timestamp: 2026-10-16T07:25:21.353Z (1792135521353945)
App: com.mci.demo.seed.safari
Window: Snowflake Arctic Embed S — Hugging Face
URL: https://huggingface.co/Snowflake/snowflake-arctic-embed-s
Summary: (none)
Entities: (none)
Text:
[app=com.mci.demo.seed.safari | title=Snowflake Arctic Embed S — Hugging Face | url=https://huggingface.co/Snowflake/snowflake-arctic-embed-s | ts=2026-10-16T07:25:21.353Z]
Arctic Embed S produces 384-dimensional local embeddings. Hippocampus combines them with FTS5 lexical ranking; semantic recall remains explicitly unavailable when the model artifact is absent.
```

The other commands:

```bash
mci-brain search "SQLCipher" --limit 5   # moments that contain the words
mci-brain recent --limit 5               # newest first
mci-brain export --format jsonl          # everything, one moment per line
mci-brain export --format csv --out memory.csv
mci-brain stats --json
```

`mci-brain search` matches words only (SQLite FTS5). Search by meaning needs the embedding model, which this command doesn't load. `mci-brain` opens the file read-only at the SQLite level, so it can't change it.

To point it at the demo yourself, set `MCI_DEVELOPMENT_FILE_KEY=1`, `MCI_DB_KEY_HEX` to the key in `hippocampus-demo/demo.key`, and `MCI_DB_PATH` to `hippocampus-demo/demo.sqlite`; the script prints the lines. `rm -rf ./hippocampus-demo` deletes the demo and its only key.

## Demo Memory

Option-click the hi in the menu bar and choose Use Demo Memory…, or open Preferences, under About. Hippocampus makes a made-up week at a made-up company in a folder of its own, pauses remembering, and opens the window on it with a small Demo tag; the menu, Ask's footer and the window's footer say Demo Memory. Leave Demo Memory, in the same places or in the window's status menu, goes back to your own memory, which is untouched.

The week is made by code in this repo, the same way every time, with its dates moved to this week:

```bash
cargo build -p mci-agent --bin mci-seed-brain
./scripts/swift-package.sh build --package-path apps/demo-memory --product demo-screens
```

Before filming: AI tools you connected still read your own memory while Demo Memory is in use, so disconnect them first if you film one; and Resume says "Made up for the demo, so nothing opens." for the week's files, documents, made-up sites and folders, except the project's own folder, which Demo Memory makes, empty, so Resume opens it in your editor and Terminal. Its pages on real sites, and Open Link, open in your own browser, so use a browser profile with no accounts signed in.

## Your calendar

Off until you turn it on: Today offers Show Calendar once, and Preferences has Show my calendar on Today, under General. macOS then asks to let Hippocampus read your calendars; it calls this full access, and Hippocampus only reads. Each event's title, time, calendar name and place are read on this Mac to draw today's meetings over your day, name a call after its meeting, list an item's meetings and answer "when did I last meet …" in Ask. Nothing from the calendar is stored or sent, and attendees are never read. Turn it off in Preferences, or in System Settings › Privacy & Security › Calendars; Today then drops the meetings ([ADR-0049](decisions/0049-calendar.md)).

While Demo Memory is in use, the window shows the week's made-up calendar and Ask leaves yours out.

## Pictures of other windows

Hippocampus keeps a screenshot of the window you're in. It also keeps one of another window you can see when that window's text changes, so History shows the chat beside your editor as it looked. Every window in front of it is blanked out, and none is kept of a call or video app, a window whose title names a call or a video site, a private window or anything skipped. These pictures use at most 2 GB, or 2% of the disk if that is less, and are thinned out as they age; Preferences, under Remembering, sets 1, 2 or 5 GB, turns them off, or forgets them while keeping their text. On a Mac that used an earlier version, they stay off until you turn them on ([ADR-0047](decisions/0047-side-window-pictures.md)).

## Search by meaning in a source build

The app bundles the embedding model, Snowflake Arctic Embed S. A source checkout doesn't: `models/` is empty until you convert it. A source build's `mci-agent` also uses the model inside an installed `/Applications/Hippocampus.app`.

To convert it, follow [the Core ML conversion guide](coreml-conversion-howto.md). In short, with Python 3.12:

```bash
python3.12 -m venv .venv-ml && source .venv-ml/bin/activate
pip install -r scripts/requirements-ml.txt
python scripts/convert_embedder.py --output models/ArcticEmbedS_FP16.mlpackage --verify
```

That writes the `.mlpackage` and a compiled `.mlmodelc` beside it. The `.mlmodelc` is the one that runs; Core ML can't open a bare `.mlpackage` at runtime. Then fill in the vectors for moments that have none:

```bash
export MCI_ARCTIC_MODEL_PATH=models/ArcticEmbedS_FP16.mlmodelc
mci-agent embed-backfill
```

`embed-backfill` refuses to run without a working model rather than write empty vectors, and running it twice does nothing the second time. `mci-agent mcp-serve` picks keyword-only or hybrid search when it starts, so restart your AI tool afterwards.

The model runs on the CPU on purpose; the reasons are in [`adapters/macos/mci-embed-coreml/src/lib.rs`](../adapters/macos/mci-embed-coreml/src/lib.rs). `cargo test -p mci-embed-coreml --test quality` embeds 50 sentences and compares each with a reference from the original weights; every one must reach a cosine of 0.999. Without the model it skips and says so.

## Keep an app out

Hippocampus skips password managers and authenticator apps (a list of 66 identifier families) and a few system apps by bundle ID ([PRIVACY.md](../PRIVACY.md#what-is-skipped)). To keep out another app, a website or a window, list it in `~/Library/Application Support/MCI/denylist.toml`:

```toml
# An app, by its exact bundle ID.
[[denylist]]
kind = "appBundle"
pattern = "com.example.app"

# Any address that starts with this.
[[denylist]]
kind = "urlPrefix"
pattern = "https://bank.example.com/"

# Any window whose title contains this.
[[denylist]]
kind = "windowTitleSubstring"
pattern = "Payroll"
```

Find an app's bundle ID with `osascript -e 'id of app "KeePassXC"'`. Matching is exact and case-sensitive. An address rule also applies to an address Hippocampus reads in a browser's top bar.

The capture helper reads the file when it starts, so restart Hippocampus afterwards (Preferences, Advanced, Restart Hippocampus). If the file has a mistake, the helper refuses to start, so nothing is read until you fix it.

## Pull in your other MCP servers

The MCP server lets an AI tool ask Hippocampus what you saw. This is the other direction: Hippocampus asks your own MCP servers what they have and keeps it, so a search covers your screen and your connectors at once.

```bash
mci-agent mcp-sync
```

It makes one pass over every server you listed, then exits. List them in `~/Library/Application Support/MCI/mcp-servers.toml`, one block each:

```toml
[[server]]
name = "my-server"                       # required, unique, [a-zA-Z0-9_-]
url  = "http://127.0.0.1:7890/mcp"       # required, on this Mac
# auth_header = "Bearer sk-..."          # optional, sent as Authorization
# enabled = true                         # optional, true by default
```

The file must be yours and mode 0600, or it is refused, because `auth_header` can hold a real token:

```bash
touch ~/Library/Application\ Support/MCI/mcp-servers.toml
chmod 600 ~/Library/Application\ Support/MCI/mcp-servers.toml
```

What to know:

- **The address must be on this Mac:** 127.0.0.1 or localhost. Anything else is refused.
- **Every moment it stores is tagged `mcp:<name>`** as its app, so you can always tell a connector's moments from your screen's.
- **Large resources are stored as a pointer.** Anything over 512 KB keeps its URI and details but not its body.
- **Running it again stores nothing new** for a resource it already has.
- When Hippocampus is remembering, its agent reads the same list when it starts.

`apps/agent/tests/mcp_sync.rs` runs the whole path against a local MCP server. It hasn't been tried against third-party servers.

## Settings without a switch

| Setting | What it does |
| --- | --- |
| `defaults write ai.hippocampus WholeScreenCapture -bool NO` | Reads only the window in front. Restart Hippocampus afterwards. |
| `defaults write ai.hippocampus ai.hippocampus.browser.readAddressesWithAutomation -bool YES` | Saves page addresses read through Automation, in browsers you allowed, so Today and Looked Up can list searches without the browser extension. Off unless set; a yes to Automation alone never turns it on. |
| `MCI_DB_PATH` | The memory file the command line opens. Default: `~/Library/Application Support/MCI/mci.sqlite`. |
| `MCI_ARCTIC_MODEL_PATH` | Where the command line finds the embedding model. |
| `MCI_EMBEDDER_DISABLED=1` | `mcp-serve` searches by words only. |
| `MCI_BRIEFS_DISABLED=1` | Turns off the daily briefs the agent writes. Nothing in the window shows them yet. |
| `MCI_DEVELOPMENT_FILE_KEY=1` | Development builds only: lets the command line use a raw key (`MCI_DB_KEY_HEX`) or the key file `dev.key` in the data folder instead of the Keychain. |

## Build requirements

| What | Version | Needed for |
| --- | --- | --- |
| macOS on Apple silicon | 14 or later | Everything |
| Xcode | 26 | The Swift apps and helper |
| Rust | The version in [`rust-toolchain.toml`](../rust-toolchain.toml) (1.96.0) | The agent and the command line |
| Python and uv | 3.12 | Building the OCR worker ([`tools/ocr/README.md`](../tools/ocr/README.md)) |
| ripgrep and SwiftFormat | Any recent | `scripts/check.sh` |
| openssl | Ships with macOS | `scripts/try-it.sh` |

The demo needs only Rust and openssl.

## Uninstall

1. If you want your memory gone, delete everything first, on the window's Privacy page. That deletes its key too, so copies in earlier backups can't be read. With Hippocampus quit, `/Applications/Hippocampus.app/Contents/MacOS/mci-agent erase-memory` does the same.
2. Disconnect your AI tools: Preferences, AI Tools, Disconnect All… ([PRIVACY.md](../PRIVACY.md#disconnecting-an-ai-tool)).
3. Quit Hippocampus and move it to the Trash.

With Homebrew, `brew uninstall --cask hippocampus` removes the app and keeps your memory. `brew uninstall --zap --cask hippocampus` also deletes your memory, logs and settings, and that can't be undone.

Unless you deleted everything first, the database key stays in your login Keychain as `ai.hippocampus.brain`. Delete it in Keychain Access if you won't reinstall.

## Troubleshooting

Start with `mci-agent doctor`. It opens memory read-only and says what is wrong in plain words.

**`cargo: command not found`.** Install Rust from [rustup.rs](https://rustup.rs), then open a new terminal so `~/.cargo/bin` is on your PATH.

**`try-it.sh` fails on the build step.** The first build compiles the whole workspace and takes a few minutes. If it fails outright, run `cargo build -p mci-agent --bins` on its own to see the real error.

**Key errors in the demo.** A development key must be exactly 64 hex characters. `openssl rand -hex 32` makes one. A wrong key doesn't give a helpful error; the file just won't open, because that is what encryption means.

**Search returns nothing.** Check `mci-brain stats` first. `Events: 0` means the demo didn't seed. Otherwise your words may not be in it; the made-up memory is about screen capture and storage, so try `ScreenCaptureKit`, `embedding` or `privacy`.

**A command says another writer owns the brain lease.** Hippocampus's agent holds it while it remembers. Quit Hippocampus, run the command, and open Hippocampus again.

**Gatekeeper says a build can't be opened.** Releases are signed with a Developer ID and notarized, and open without a warning. A copy you built yourself with `--development-ad-hoc` isn't; open it from Finder with Control-click, Open.
