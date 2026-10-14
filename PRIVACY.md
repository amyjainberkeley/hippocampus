# Privacy

Hippocampus remembers what is on your screen so you, and your AI if you choose, can use it later. This page says what it keeps, where, what leaves your Mac and when, and how to stop it. It links the code that keeps each promise, so you can check rather than trust.

## The promises

- **You can always tell.** A solid dot in the menu bar means it is remembering. No solid dot means it is not.
- **It stays on your Mac.** Encrypted on disk. Nothing is uploaded by Hippocampus. There is no account and no server.
- **Some things are never read.** Password fields and password managers. Private browser windows are skipped when they show they are private, and a short built-in list of bank and sign-in sites when their address shows.
- **Your AI sees it only if you connect it.** What a connected AI tool reads goes to the company that runs that tool.
- **You can stop it.** Pause from the menu bar. Quit, or Stop Sharing in macOS, ends it.
- **Deleting is real.** Delete the last 24 hours or everything, and what was learned from it goes too.
- **No keylogging, no audio.** It reads what is on screen. It counts key presses to tell typing from reading, never which keys.

## What is stored

- Text read from your screen, with the app, the window title, the page address when there is one, and the time. The window you are working in is read when it changes. Other visible windows, on every display, are read when their text changes ([ADR-0040](docs/decisions/0040-whole-screen-background-capture.md)).
- Some screenshots of the window you were working in. None of the other windows on screen.
- Sessions, a summary of your day, and what it learned about you, each linked to the moments it rests on. They are written on this Mac, by Apple Intelligence or by a model you run yourself.
- Search data made from that text, so you can search by meaning.
- Activity counts: how many keys, clicks and scrolls every few seconds, to tell typing from reading. Never which keys.
- Nothing is heard. macOS calls the permission “Screen & System Audio Recording”, and Hippocampus does not listen.

## Where it is kept

- Text, sessions and search data are in one encrypted database (SQLCipher) in `~/Library/Application Support/MCI/`. Screenshots are separately encrypted files beside it, in `MCI/blobs/`.
- The key is in your login Keychain and is not synced. AI tools you connect are given a Keychain reference, never the key. A development build can use a file key (`dev.key`, mode 0600) only when `MCI_DEVELOPMENT_FILE_KEY=1` is set.
- Everything is kept for 90 days, unless you choose otherwise in Preferences, under Privacy. Anything older is deleted for good.

The data folder (~/Library/Application Support/MCI) and two background processes (mci-agent, MCICaptureHelper) carry MCI, the project’s early working name.

## What leaves your Mac

Nothing you saw leaves your Mac unless you do one of these:

- **Connect an AI tool**, such as Claude Code or Codex. If you let it, each session starts with your recent work and up to six things Hippocampus learned about you, each with its sources. When it needs more, it can search your memory. What it reads goes to the company that runs that tool, under that company’s terms. A connected tool starts its own reader of your memory, so it can still read while Hippocampus is quit. Disconnect it in Preferences, under AI Tools, to stop that.
- **Copy for your AI.** The text goes to your clipboard, and you paste it where you choose.
- **Use a model you run yourself.** If answers come from Ollama or LM Studio, Hippocampus sends that server the text an answer needs. It talks only to model servers on this Mac (127.0.0.1, ::1 or localhost), follows no redirects, and never picks a model that runs in the cloud. Some servers can send text on to the cloud, so pick a model that runs on your Mac.

These requests carry nothing you saw:

- The updater (Sparkle) checks `amyjainberkeley.github.io/hippocampus/appcast.xml` for a newer version when you ask, or daily if you turn on automatic checks. It verifies an update’s signature before installing it.
- A copy that ships without its models downloads them once from a public host.
- `mci-agent mcp-sync` reads from MCP servers you register yourself, and refuses any address that is not on this Mac.

There is no analytics and no telemetry ([ADR-0025](docs/decisions/0025-analytics-telemetry-policy.md)). Crash reports stay off unless you set both `MCI_CRASH_REPORT_URL` and `MCI_CRASH_REPORT_OPTED_IN=1`, and then go only to an address on this Mac.

## What is never read

- Password fields. While one is active, nothing is read, and the menu-bar dot turns hollow.
- Password managers, Apple’s Passwords and Keychain Access.
- System Settings, sign-in dialogs and the lock screen.
- Protected video, and Hippocampus’s own windows.
- Private browser windows are skipped when they show they are private: Incognito, InPrivate or Private Browsing in the window’s title or top bar. A short built-in list of bank and sign-in sites is skipped the same way, when the site’s address shows there. Both are checked before anything is stored.
- Text that looks like a one-time code, a bank alert, a password or an access key is refused before it is stored. The fixtures for that check are in [`core/brain/fixtures/`](core/brain/fixtures/).

Browsers are read like every other window, with no extension and no Automation prompt. Hippocampus never asks for Automation to check whether a window is private.

## How to stop it

- Pause from the menu bar. It stays paused until you resume it.
- Quit from the menu bar, or press ⌘Q. Everything Hippocampus runs stops.
- Stop Sharing in macOS’s screen-recording menu. Hippocampus turns off until you turn it on.
- Take back a permission any time in System Settings, under Privacy & Security.

## How to delete it

- The last 24 hours, or everything: open Preferences, then Privacy, then See or Delete What’s Remembered…. Either asks you to confirm first, and what was learned from those moments goes too. Deleting rewrites the database file, so the old pages are gone.
- You can export it all as JSON in the same place. The exported file isn’t encrypted.
- Something it learned about you: Forget, on the You page.
- Removing the app: disconnect your AI tools in Preferences, quit Hippocampus, then move it to the Trash. Delete everything first if you want your memory gone too.

## Where this is decided

- [ADR-0001: privacy posture](docs/decisions/0001-privacy-posture-local-first-e2e.md)
- [ADR-0013: what is never read](docs/decisions/0013-native-grade-sensitive-surface-suppression.md)
- [SECURITY.md](SECURITY.md) for reporting a gap.
