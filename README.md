<p align="center"><img src="assets/branding/AppIcon.iconset/icon_128x128@2x.png" width="128" height="128" alt="The Hippocampus icon: the letters hi in navy on a white tile, the dot of the i in blue"></p>

<h1 align="center">Hippocampus</h1>

<p align="center"><strong>Computers should learn from the way you work.<br>First, they have to remember it.</strong></p>

<p align="center">Hippocampus remembers what’s on your screen and learns how you work, in words you can check.<br>It’s open source, and your memory stays encrypted on your Mac.</p>

<p align="center">
  <a href="https://github.com/amyjainberkeley/hippocampus/releases/latest/download/Hippocampus.dmg"><strong>Download for Mac</strong></a><br>
  <sub>macOS 14 or later, Apple silicon. Free and open source.</sub>
</p>
<!-- SITE_LINK: when the site is live, add its address here, for example: <p align="center"><a href="https://…">Website</a></p> -->

<p align="center">
  <img src="docs/media/ask-answer.png" width="720" alt="Ask, dropped from the menu bar, answers “What did we decide on Team pricing?”: you and Ravi settled on $18 a seat for Team, billed annually. Its sources follow, this window first, then a Slack message and a note.">
  <br><sub>Sample data.</sub>
</p>

## Install

```bash
curl -fsSL https://github.com/amyjainberkeley/hippocampus/releases/latest/download/install.sh | sh
```

It downloads the latest release, checks its checksum, Apple’s notarization and the developer’s signature, and copies Hippocampus to Applications. It also puts the `mci-agent` command on your PATH. [scripts/install.sh](scripts/install.sh) says every step.

Or with Homebrew:

```bash
brew install --cask amyjainberkeley/tap/hippocampus
```

Or [download the disk image](https://github.com/amyjainberkeley/hippocampus/releases/latest/download/Hippocampus.dmg) and drag Hippocampus to Applications.

Setup is five short screens. It shows what you get first, then asks for two permissions, Screen Recording and Accessibility, and reads nothing until you click Start Remembering.

## What it does

**Today.** Where you left off, with its screenshot, and your day as sessions you can click. Resume reopens what you had open for that project: its pages, documents, code folder and apps, only the ones you tick.

**Working On.** Your projects and documents by name, from their window titles. Each has a page with where you left off, its files, the pages you read alongside it, its meetings and its history.

**History.** Every moment, newest first, as it read on screen: headings, paragraphs, lists, code and chats. Web Pages, Documents, Code, Conversations and Looked Up show the same moments by kind.

**Ask.** Press Shift twice (or Fn, if you choose it) and Ask drops from the menu bar over any app, like Spotlight. It finds projects, pages and moments as you type, and answers questions with sources, this window first. ⌃⇧Space works too.

**Your AI tools start with what you’re working on.** Connect Claude Code or Codex from the menu bar. They can then search your memory through the `hippocampus` MCP server, with tools such as `recall`, `context` and `person_model`. If you let them, a session starts with up to four lines of your recent work and up to six things learned about you, with sources: every Claude Code session, and every Codex session once you allow its hook in Codex. Until then, or with Codex’s hooks turned off, Codex is asked to fetch your recent work when a task starts, and Codex decides. Ask Claude opens Claude, Codex or Cursor with what you picked already in its message box, and you press send; for ChatGPT it is copied, ready to paste. AI Tools shows the exact words each tool gets.

**About You.** What Hippocampus has learned about you, in the exact words your AI tools are given, with the moments behind each line. Mark what’s right. Forget what isn’t.

**Your calendar, if you want it.** Today’s meetings over your day, and calls named after them. It is off until you turn it on, and read only on your Mac.

Answers and summaries need Apple Intelligence (macOS 26) or a model on your Mac. Hippocampus finds Ollama or LM Studio by itself. Without either, search still works.

## Privacy

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/branding/hi-states-dark.svg">
    <img src="assets/branding/hi-states-light.svg" width="540" alt="The four menu-bar pictures: hi with a solid dot, remembering. hi with a hollow dot, a password field, nothing is read. A dimmed h and i with no dot, paused or off. h with an exclamation mark, needs you.">
  </picture>
</p>

- **You can tell.** A solid dot means it is remembering. No solid dot means it is not.
- **Your memory stays on your Mac, encrypted.** Hippocampus itself has no cloud service. There is no account, no telemetry and no crash reporting, and it uploads nothing you saw.
- **Some things are skipped.** Password fields, password managers and authenticator apps, private browser windows that show they are private, and a list of bank, sign-in and password-manager sites. Text in a few secret shapes is refused before it is stored: a password, secret, API key or token written as `name: value`, a GitHub token, an AWS access key ID, a JSON web token, a card number that passes the Luhn check, and a one-time code next to words like “verification code”. These are rules, so a lone code with no such word nearby, or a bank alert on screen, can be kept. [PRIVACY.md](PRIVACY.md#what-is-skipped) says exactly what they catch and miss.
- **Screenshots are kept, encrypted.** Of the window you’re in, and of other windows you can see when their text changes, each sealed in its own file. A picture of another window shows only that window: anything in front of it is blanked out, and none is kept of a call, a video or a private window it recognizes. Those pictures use at most 2 GB, or 2% of the disk if that is less (1, 2 or 5 GB in Preferences), are thinned out as they age, and Preferences turns them off ([more](PRIVACY.md#what-is-stored)).
- **Your AI tools get it only if you connect them, or send it yourself.** What a connected tool reads goes to the company that runs it. So does what you send. Ask Claude opens the tool with the message in its box, and nothing is sent until you press send. A connected tool can read your memory while Hippocampus is quit, until you [disconnect it](PRIVACY.md#disconnecting-an-ai-tool) in Preferences, under AI Tools, and restart the tool.
- **You can stop it.** Pause from the menu bar. Quit, or Stop Sharing in macOS, stops remembering.
- **Forgetting is real.** Forget a moment, a session, the last 10 minutes, the last hour, today or everything, and what was learned from it goes too.

[PRIVACY.md](PRIVACY.md) says what is stored, where, every request the app makes, and its threat model. [SECURITY.md](SECURITY.md) says how to report a gap.

## What it costs

Reading the screen is the cost. The numbers below are measured, each with its source. A full day’s CPU, memory and battery use hasn’t been measured yet; [docs/STATUS.md](docs/STATUS.md) will carry it when it is.

| | Measured | Source |
| --- | --- | --- |
| Reading one window | 3.7 to 4.8 CPU-seconds and about 4 J at the median; 1.3 to 1.7 GB peak memory while reading | [Reader bake-off](eval/ocr-bakeoff-2026-10-15.md), MacBook Air M3, made-up screens |
| Lines read exactly, on the bench’s flat screens | 96.7% (Apple Vision, tuned: 93.9%) | The same bake-off |
| Disk image | 180 MB | The same bake-off, a 0.3.0 candidate with this reader |
| Installed app | 370 MiB, 243 MiB of it the reader | The same bake-off |

How hard it may work is set in code, not measured: the window in front is read at most every 3 seconds, other windows at most every 30, and after each read the reader rests three times as long as the read took. On battery those rests are longer, and in Low Power Mode only the window in front is read ([PRIVACY.md](PRIVACY.md#what-is-stored)).

The reader is PP-OCR, bundled. It reads code and small text more exactly than Apple Vision on the repo’s bench, and costs 8 to 10 times Vision’s CPU per read. To check the numbers yourself, run `tools/ocr/screens/bakeoff.py` with the capture helper’s `OCRQualityProbe`, as the bake-off’s Reproduce section shows.

This is a beta. [docs/STATUS.md](docs/STATUS.md) says what works today and how it was checked.

## Build from source

You need Xcode 26, the Rust toolchain named in [rust-toolchain.toml](rust-toolchain.toml), and Python 3.12 with [uv](https://docs.astral.sh/uv/) for the text reader.

```bash
git clone https://github.com/amyjainberkeley/hippocampus.git && cd hippocampus
./scripts/try-it.sh    # search over a made-up memory, with no permissions
./scripts/check.sh     # every check, as CI runs them
```

To build a disposable copy of the app for your own Mac:

```bash
uv venv tools/ocr/.venv --python 3.12
uv pip install --python tools/ocr/.venv/bin/python --require-hashes --no-deps -r tools/ocr/requirements.txt
env -i HOME="$HOME" PATH=/usr/bin:/bin tools/ocr/.venv/bin/python tools/ocr/prepare.py
cargo build -p mci-agent --bins -p hippocampus-native-host
for package in apps/hippocampus adapters/macos/MCICaptureHelper apps/recall-ui apps/onboarding apps/mind apps/demo-memory; do
  ./scripts/swift-package.sh build --package-path "$package"
done
./apps/hippocampus/Resources/build-app.sh --debug --development-ad-hoc --development-lite
```

A development copy uses the same data folder as an installed one, so build it under a separate macOS user. [docs/GUIDE.md](docs/GUIDE.md) covers the command line, [scripts/README.md](scripts/README.md) covers signed builds and releases, [ARCHITECTURE.md](ARCHITECTURE.md) is the map, and [CONTRIBUTING.md](CONTRIBUTING.md) says how to send a change.

## Built on research

Hippocampus learns the way a general user model does (Shaikh et al., 2025). It keeps what it learns as a personal context model: plain statements on your Mac, each linked to the moments behind it, in the exact words your AI tools receive. You can read each one, mark it right, or remove it.

Omar Shaikh, Shardul Sapkota, Shan Rizvi, Eric Horvitz, Joon Sung Park, Diyi Yang and Michael S. Bernstein. [Creating General User Models from Computer Use](https://arxiv.org/abs/2505.10831). 2025.

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
