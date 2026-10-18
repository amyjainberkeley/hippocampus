# Privacy

Hippocampus remembers what is on your screen so you, and the AI tools you choose, can use it later. This page says what it keeps, where, what leaves your Mac and when, and how to stop it. It links the code that does each thing, so you can check rather than trust.

## In short

- **You can tell.** A solid dot on the hi in the menu bar means it is remembering. A hollow dot means a password field is active and nothing is read. No dot means it is paused or off.
- **It stays on your Mac, encrypted.** Hippocampus has no server and no account, and uploads nothing you saw.
- **Some things are skipped before anything is stored.** Password fields, six password managers, private browser windows that show they are private, and a short list of bank and sign-in sites. The rules, and what they miss, are below.
- **Your AI tools read it only if you connect them.** What a connected tool reads goes to the company that runs it.
- **You can stop it.** Pause from the menu bar, Quit, or Stop Sharing in macOS.
- **Deleting is real.** Delete the last 24 hours or everything, and what was learned from those moments goes too.
- **Counts, not keystrokes.** It counts key presses to tell typing from reading. It doesn't record which keys, or any sound.

## What is stored

- Text read from your screen, with the app, the window's title, the time, and the page's address when a browser gives it (where you already allowed Automation, or with the optional extension).
- The window you are working in is read when it changes: at most every 3 seconds plugged in, 6 on battery and 12 in Low Power Mode, and every 15 seconds or more while it keeps moving, as a video does ([FocusedReadPacing.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/FocusedReadPacing.swift)).
- The other windows you can see, on every display, are read when their text changes: at most every 30 seconds plugged in and every 60 on battery. In Low Power Mode only the window you are working in is read ([CapturePower.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/CapturePower.swift), [ADR-0041](docs/decisions/0041-browsers-and-reading-cadence.md)).
- After every read the reader rests: three times as long as the read took when plugged in, eight times on battery, sixteen in Low Power Mode ([CaptureReadBudget.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/CaptureReadBudget.swift)).
- Some screenshots of the window you were working in. None of the other windows.
- Sessions, a summary of your day, and what it learned about you, each linked to the moments behind it. They are written on this Mac, by Apple Intelligence or by a model you run yourself.
- Search data made from that text, so you can search by meaning.
- Activity counts: how many keys, clicks and scrolls every few seconds. Never which keys.
- **Mail and Messages, only if you turn them on.** Under Preferences, Choose Apps…, these two apps offer "Capture + Deep hook". With that on and Full Disk Access granted, Hippocampus also stores new messages from their files on this Mac, after taking out one-time codes, bank alerts and the text of mail from banks ([messages_ingest.rs](apps/agent/src/messages_ingest.rs), [mail_ingest.rs](apps/agent/src/mail_ingest.rs)). Both are off until you choose them.

macOS calls the permission "Screen & System Audio Recording". Hippocampus asks for it to see the screen, and records no sound.

## Where it is kept

- Text, sessions and search data are in one encrypted database (SQLCipher) in `~/Library/Application Support/MCI/`. Screenshots are separately encrypted files beside it, in `MCI/blobs/`.
- The key is in your login Keychain and is not synced. AI tools you connect are given a Keychain reference, never the key. A development build can use a file key (`dev.key`, mode 0600) only when `MCI_DEVELOPMENT_FILE_KEY=1` is set.
- Everything is kept for 90 days, unless you choose otherwise in Preferences, under Privacy. Anything older is deleted for good.
- Logs and crash records are in `~/Library/Logs/MCI/`.
- The window keeps a plain-text log of what was done to your memory: launches, deletions and exports, with counts, times and an export's file path, never what you saw. It is `~/Library/Application Support/Hippocampus/audit.log`, and deleting your memory leaves it.

The data folders and two background processes (mci-agent, MCICaptureHelper) carry MCI, the project's early working name.

## What leaves your Mac

Hippocampus uploads nothing you saw. What you saw leaves your Mac only in one of these ways:

- **You connect an AI tool**, such as Claude Code or Codex. It is added to the tool as an MCP server named `hippocampus`. While it is connected, the tool can search all of your memory and read moments, sessions, your day and what Hippocampus learned about you. If you let it, each session also starts with up to four lines of recent work and up to six things learned about you, with sources ([query.rs](apps/agent/src/understanding/query.rs)). Those six can include guesses you haven't confirmed. You shows each one, and Forget removes it. A connected tool starts its own reader of your memory (`mci-agent mcp-serve`), so it can read while Hippocampus is quit. What it reads goes to the company that runs the tool, under that company's terms.
- **You use Copy for your AI.** The text goes to your clipboard, and you paste it where you choose.
- **You use a model you run yourself.** If answers come from Ollama or LM Studio, Hippocampus sends that server the text an answer needs. It talks only to servers on this Mac (127.0.0.1, ::1 or localhost), follows no redirects, and skips Ollama's cloud models, whose names end in `-cloud` or `:cloud` ([LocalServerEngine.swift](apps/mind/Sources/MindKit/LocalServerEngine.swift)). Some servers can pass text on to the cloud, so pick a model that runs on your Mac.

These requests carry nothing you saw:

- The updater (Sparkle) asks `github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml`, which GitHub serves from `release-assets.githubusercontent.com`, whether there is a newer version. It asks when you click Check for Updates, or daily if you turn on automatic checks. It checks an update's signature before installing it.
- If you list MCP servers in `~/Library/Application Support/MCI/mcp-servers.toml`, Hippocampus reads from them. It refuses any address that is not on this Mac.

There is no analytics and no telemetry. Preferences has a Send crash reports switch, but this version has no address to send them to, so crash records stay in `~/Library/Logs/MCI/panic.jsonl`. ADR-0025, which planned opt-in analytics, is withdrawn.

### Disconnecting an AI tool

Hippocampus can't disconnect a tool for you yet. To do it yourself:

1. In Preferences, under AI Tools, turn off "Start each session with what I'm working on" for that tool.
2. Remove the server from the tool. For Claude Code, run `claude mcp remove hippocampus`. For Codex, delete the `[mcp_servers.hippocampus]` table from `~/.codex/config.toml`.
3. Restart the tool. What it already read stays in its history.

## What is skipped

These checks run before anything is stored. They are rules, so they catch what they were built and tested for, and they can miss.

- **Password fields.** While one is active anywhere on screen, nothing is read, and the menu-bar dot turns hollow.
- **These apps, by bundle ID:** 1Password, Bitwarden, Dashlane, LastPass, Apple's Passwords and Keychain Access; System Settings, sign-in and permission dialogs, the lock screen and the screen saver; and Hippocampus's own windows ([CaptureAdmissionPolicy.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/CaptureAdmissionPolicy.swift)). Other password managers are read like any other app, with the checks below. You can add any app to your own list ([GUIDE.md](docs/GUIDE.md#keep-an-app-out)).
- **Notification banners** stay out of the reads of other windows, because they often carry one-time codes.
- **Protected video.** macOS blacks it out of screen captures, and a blacked-out area stops that read.
- **Private browser windows that show they are private:** Incognito, InPrivate or Private Browsing in the window's title or top bar. A private window that shows none of these is read.
- **A short list of bank and sign-in sites** (18 addresses, in the same file), when the site's address shows in the window's title or address bar.
- **Text in a few secret shapes** is refused before it is stored: a password, secret, key or token written as `name: value` or `name = value`, a GitHub token, an AWS access key ID, a JSON web token, a credit-card number that passes the Luhn check, and a one-time code — a 4-to-8 digit number shown next to words like "verification code", "one-time", "passcode", "OTP" or "2FA". Every saved moment is checked three times: the text as read, the page in reading order, and the exact text saved ([SuppressionCascade.swift](adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift), fixtures in [`core/brain/fixtures/`](core/brain/fixtures/)). These rules lean toward leaving ordinary numbers alone: a card number is skipped only when it passes the Luhn check, so phone numbers, order ids and dates are kept, and a lone code with no nearby word, or a one-time code in a format those words don't name, can still be stored. A bank alert shown on screen is not one of these shapes either; the Messages and Mail deep hook, if you turn it on, takes bank alerts out on its own path.

Browsers are read like every other window, with no extension and no Automation prompt. Hippocampus doesn't ask for Automation to tell whether a window is private.

## How to stop it

- Pause from the menu bar. It stays paused until you resume it, even across restarts.
- Quit from the menu bar, or press ⌘Q. Everything Hippocampus started stops. A connected AI tool's own reader keeps running until you close that tool.
- Stop Sharing in macOS's screen-recording menu. Hippocampus turns off until you turn it on.
- Take back a permission any time in System Settings, under Privacy & Security.

## How to delete it

- The last 24 hours, or everything: open Preferences, then Privacy, then See or Delete What's Remembered…. Either asks you to confirm first, and what was learned from those moments goes too. The database file is then rewritten without them.
- You can export it all as JSON in the same place. The exported file isn't encrypted.
- Something it learned about you: Forget, on the You page.
- Removing the app: disconnect your AI tools (above), quit Hippocampus, then move it to the Trash. Delete everything first if you want your memory gone too.

## Threat model

- **Encryption protects the memory at rest.** A copy of the database or a screenshot file, in a backup or on a lost disk, can't be read without the key in your login Keychain.
- **It doesn't protect against software running as you.** A program that runs under your login can read your screen itself, or start Hippocampus's own `mci-agent` and read your memory the way a connected AI tool does. Keep malware off your Mac; Hippocampus can't tell it from you.
- **A connected AI tool can read all of your memory**, a search at a time, for as long as it is connected, including while Hippocampus is quit.
- **Screen text can carry instructions aimed at an AI.** Session-start text and `mci-agent context` begin by telling the AI that memory is reference, never instructions. Search results carry no such line. A page written to steer an AI can still steer one, so review what a connected tool proposes to do.
- **The skipping rules above are pattern rules.** A password shown in plain text in an app they don't know, or a secret in a shape the checks don't catch, can be stored. Then delete it, and report the shape ([SECURITY.md](SECURITY.md)).

## Where this is decided

- [ADR-0001: privacy posture](docs/decisions/0001-privacy-posture-local-first-e2e.md)
- [ADR-0013: what is never read](docs/decisions/0013-native-grade-sensitive-surface-suppression.md)
- [ADR-0041: browsers and how often windows are read](docs/decisions/0041-browsers-and-reading-cadence.md)
- [SECURITY.md](SECURITY.md) for reporting a gap.
