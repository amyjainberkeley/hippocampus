# Hippocampus Status

_Updated October 13, 2026, for 0.3.0._

Audited code baseline: `4df194f`

The release build checks that this commit is an ancestor of `HEAD` and at most
three commits behind it, so this page is refreshed with every release. It says
what works today and how each part was checked. The README and the app never
claim more than this page.

## What works

| Part | Today | How it was checked |
| --- | --- | --- |
| Reading the screen | Every window on every display is read, the one in front most closely. Panes are found and read in order. | The capture package's Swift tests, parity fixtures against the reference reader (`tools/ocr/screens/layout.py`), and the transcript bench below. |
| What is never read | Password fields, password managers, private browser windows that show they are private, and a built-in list of bank and sign-in sites. | Swift tests for each rule, including the private-window markers, and three secret scans on every saved moment. |
| Encrypted memory | One SQLCipher database with its key in the login Keychain. Screenshots are separately encrypted files. | Rust tests for the store, deletion and key custody. |
| Search | Exact words and meaning (Arctic Embed S on Core ML). | Rust tests and the evaluations in [`docs/eval/`](eval/). |
| Ask | Shift twice opens it over any app. Matches appear as you type. Return asks for an answer with sources. | The menu-bar app's Swift tests, and renders of every panel state from fixtures. |
| Answers and summaries | Written by Apple Intelligence (macOS 26) or by a model server on this Mac (Ollama, LM Studio). Without one, search still works. | The model package's tests, also built and run without Foundation Models. A missing server reports itself as unavailable. |
| Overview and You | Your day as sessions, a Right now card, a summary, and what your AI can be told about you. | The window's Swift tests, a decode of the agent's real `overview --json` and `model --page --json` output, and renders of a made-up workday. |
| AI tools | Claude Code and Codex connect from the menu bar. Each session can start with recent work and up to six things learned about you. | Rust integration tests for the session packet, the session hook and the MCP server. |
| Menu bar, Pause, Stop Sharing, Quit | Four menu-bar pictures. Quit stops every process Hippocampus started. | The menu-bar app's Swift tests, and `scripts/test-verify-quit-leaves-nothing.sh` for the Quit checker. |
| Setup | Four screens: Welcome, two permissions, the promises, and Try it. | The setup package's Swift tests and renders of each screen. |

## Measured

Reading, from `tools/ocr/screens/bench.py` over seven realistic test windows
with made-up text:

| | Before 0.3 | 0.3.0 |
| --- | --- | --- |
| Interface text mixed into what you were reading | 94% | 21% |
| Text in reading order | 0.90 | 1.00 |
| Stray symbols per window | 14.7 | 1.0 |

## Not checked yet

- The model process on a Mac running macOS 14 or 15. Its binary loads
  Foundation Models weakly, so it should start there and report answers as
  unavailable.
- Answers from a real Ollama or LM Studio server. The tests use stand-in
  servers.
- Each browser's normal and private windows on a real Mac, with the installed
  app.
- A clean install on a second Mac, and an update from 0.2.1 that keeps the
  Keychain key.
- MCP clients other than Claude Code and Codex.

## Known limits

- A private browser window that shows no private marker is read.
- Connected tools can still read your memory while Hippocampus is quit.
  Disconnect a tool to stop that.
- Memories saved before 0.3 lose the header and stray symbols when shown. A
  window read across panes stays out of order until it is read again.
- No sync between Macs, and no Windows version.

## Checks to run

- `scripts/check.sh` runs every lane CI runs. `scripts/check.sh --help` lists
  them.
- `scripts/verify-quit-leaves-nothing.sh <app>` checks a built app leaves
  nothing running after Quit.
- `apps/hippocampus/Resources/build-app.sh` refuses to assemble an app when
  this page's baseline is more than three commits behind `HEAD`. On a branch
  of your own, point the `Audited code baseline:` line at a recent commit you
  have checked.

Older status notes are in this file's git history.
