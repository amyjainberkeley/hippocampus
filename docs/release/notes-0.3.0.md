# Hippocampus 0.3

Hippocampus remembers what’s on your screen and learns how you work, in words you can check. It’s open source, and your memory stays encrypted on your Mac.

## What’s new

- **A window built around your work.** Today shows where you left off and your day. Working On names your projects from their windows. History shows every moment as it read, with its screenshot, and Web Pages, Documents, Code, Conversations and Looked Up show them by kind.
- **Resume picks up where you left off.** It reopens a project’s pages, documents, code folder and apps, only the ones you tick, and sends nothing anywhere.
- **Ask drops from the menu bar.** Press Shift twice over any app. Type to find projects, pages and moments, by meaning and by exact words, or ask a question for an answer with its sources, this window first.
- **Your AI tools start with what you’re working on.** Connect AI Tools… connects Claude Code and Codex in one step, and Ask Claude opens your tool with what you picked already in its message box.
- **About You.** What your AI tools can be told about you, in the exact words. Mark what’s right, and forget what isn’t.
- **Your calendar, if you want it.** Today’s meetings over your day, read only on your Mac.
- **Answers written on your Mac,** by Apple Intelligence or by a model you run with Ollama or LM Studio.
- **Safer by default.** The text reader runs with no network access, every source is checked for secrets before anything is stored, Delete Everything also deletes the memory’s key, and your memory stays out of Time Machine unless you include it.
- **Easier to install, and smaller.** A one-line installer and a Homebrew cask, and updates from GitHub releases.

Every change is in the [changelog](https://github.com/amyjainberkeley/hippocampus/blob/main/CHANGELOG.md).

## Install

Download `Hippocampus-0.3.0.dmg` below and drag Hippocampus to Applications, or run `brew install --cask amyjainberkeley/tap/hippocampus`. Or use the one-line installer, which runs [scripts/install.sh](https://github.com/amyjainberkeley/hippocampus/blob/main/scripts/install.sh):

```bash
curl -fsSL https://github.com/amyjainberkeley/hippocampus/releases/latest/download/install.sh | sh
```

SHA-256 of `Hippocampus-0.3.0.dmg`: `{{SHA256}}`

It needs macOS 14 or later on Apple silicon. Answers and summaries need Apple Intelligence (macOS 26) or a model on your Mac; without either, search still works. Setup is five short screens and asks for Screen Recording and Accessibility.

## Privacy

- Your memory is encrypted on your Mac. Hippocampus has no server and uploads nothing you saw.
- Password fields, password managers and authenticator apps, private windows that show they are private, and a list of bank, sign-in and password-manager sites are skipped, and text in a few secret shapes, such as API keys, card numbers and one-time codes next to words like “verification code”, is refused. These are rules, and [PRIVACY.md](https://github.com/amyjainberkeley/hippocampus/blob/main/PRIVACY.md) says what they miss.
- AI tools read your memory only if you connect them, and what they read goes to the company that runs them.
- The text reader in 0.2.0 and 0.2.1 sent ONNX Runtime’s usage events and a device ID to Microsoft. This version turns that off and runs the reader with no network access.

## Known limits

- A private browser window that shows no private marker is read.
- A one-time code with no keyword nearby, or a bank alert shown in a window, can be stored: the secret checks refuse only the shapes [PRIVACY.md](https://github.com/amyjainberkeley/hippocampus/blob/main/PRIVACY.md#what-is-skipped) lists.
- A connected AI tool can read your memory while Hippocampus is quit, until you disconnect it in Preferences, under AI Tools ([how](https://github.com/amyjainberkeley/hippocampus/blob/main/PRIVACY.md#disconnecting-an-ai-tool)).
- Copy for Your AI and Ask {your tool} send each moment’s whole reading, shortened evenly to fit the tool’s message box.
- Moments saved before 0.3 were read by the old reader: text it ran together across columns is only partly separated.

This is a beta. [docs/STATUS.md](https://github.com/amyjainberkeley/hippocampus/blob/main/docs/STATUS.md) says what was checked, and how.
