# Hippocampus 0.3

Hippocampus remembers what’s on your screen and learns how you work, in words you can check. It’s open source, and your memory stays encrypted on your Mac.

## What’s new

- **Ask drops from the menu bar.** Press Shift twice over any app. Type to find anything you’ve seen, by meaning and by exact words, or press Return for an answer with its sources, this window first.
- **Overview and You.** Your day as sessions you can click, a card for what you’re on right now, and a short summary written on your Mac. You shows, in the exact words, what your AI tools can be told about you. Mark what’s right, and forget what isn’t.
- **The whole screen, read the way you read it.** The windows you can see are read, browsers included, and private windows that show it are skipped. Code keeps its indentation, chats keep their order, and a window’s tabs, sidebars and menus come after what you were reading.
- **Your AI tools start with what you’re working on.** Connect AI Tools… connects Claude Code and Codex in one step.
- **Answers written on your Mac,** by Apple Intelligence or by a model you run with Ollama or LM Studio.
- **Quit and Stop Sharing stop.** Quit stops everything Hippocampus started and waits until it has. Stop Sharing turns remembering off until you turn it on.
- **Easier to install, and smaller.** A one-line installer and a Homebrew cask, and updates from GitHub releases.

Every change is in the [changelog](https://github.com/amyjainberkeley/hippocampus/blob/main/CHANGELOG.md).

## Install

```bash
curl -fsSL https://github.com/amyjainberkeley/hippocampus/releases/latest/download/install.sh | sh
```

Or `brew install --cask amyjainberkeley/tap/hippocampus`, or download `Hippocampus-0.3.0.dmg` below and drag Hippocampus to Applications.

SHA-256 of `Hippocampus-0.3.0.dmg`: `{{SHA256}}`

It needs macOS 14 or later on Apple silicon. Answers and summaries need Apple Intelligence (macOS 26) or a model on your Mac; without either, search still works. Setup is four screens and asks for Screen Recording and Accessibility.

## Privacy, in three lines

- Your memory is encrypted on your Mac. Hippocampus has no server and uploads nothing you saw.
- Password fields, six password managers, private windows that show they are private, and a short list of bank and sign-in sites are skipped. These are rules, and [PRIVACY.md](https://github.com/amyjainberkeley/hippocampus/blob/main/PRIVACY.md) says what they miss.
- AI tools read your memory only if you connect them, and what they read goes to the company that runs them.

## Known limits

- A private browser window that shows no private marker is read.
- A one-time code or a bank alert shown in a window can be stored; the secret checks look for passwords, keys and tokens.
- A connected AI tool can read your memory while Hippocampus is quit, and the app can’t disconnect one yet. [PRIVACY.md](https://github.com/amyjainberkeley/hippocampus/blob/main/PRIVACY.md#disconnecting-an-ai-tool) says how.
- Copy for your AI pastes short previews of each moment, with some symbols written as codes.
- Moments saved before 0.3 keep the transcripts the old reader made.

This is a beta. [docs/STATUS.md](https://github.com/amyjainberkeley/hippocampus/blob/main/docs/STATUS.md) says what was checked, and how.
