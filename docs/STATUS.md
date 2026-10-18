# Hippocampus Status

_Updated October 17, 2026, for 0.3.0._

Audited code baseline: `99bc8b7`

The release build checks that this commit is an ancestor of `HEAD` and at most
three commits behind it, so this page is refreshed with every release. It says
what works today and how each part was checked: a named test, a measurement,
or "needs a person" where only someone using a real Mac can tell. The README
and the app claim no more than this page.

## What works

`scripts/check.sh` last passed in full at `b58b48b` on October 16 — all 71
lanes, none skipped: 2,371 Rust tests; the capture helper's 967 Swift tests
(one opt-in live probe skipped), the window's 684, setup's 390, the menu-bar
app's 612 and the model process's 54; and the OCR worker's 155. The baseline
above is stamped to the commit this release builds, which is ahead of that run;
before a signed build `scripts/check.sh` must pass in full again at the stamped
commit (see [the release checklist](release/RELEASE_CHECKLIST.md)), and this
page is refreshed with each release. Each row names the tests that cover it.

| Part | Today | How it was checked |
| --- | --- | --- |
| Reading the window in front | Read when it changes: at most every 3 s plugged in, 6 s on battery and 12 s in Low Power Mode, and every 15 s or more while it keeps moving. Panes are read in order, and a window's tabs, sidebars and bars come after what you were reading. | `FocusedReadPacingTests`, `CapturePowerTests`, `OCRReadingOrderTests` and the reading-order parity fixtures (`tools/ocr/test_layout.py`), and the transcript bench below. On a real screen: needs a person. |
| Reading other windows | Every display, when text changes outside the window in front: at most every 30 s plugged in and 60 s on battery, none in Low Power Mode. Each line is filed under the window it sits in. | `BackgroundCapturePolicyTests`, `CapturePowerTests`. Two displays on a real Mac: needs a person. |
| The text reader | PP-OCR (RapidOCR 3.9.2, PP-OCRv6 small, ONNX Runtime 1.30), bundled, without FFmpeg, x264 or x265. | The OCR worker's tests (`ocr-worker` lane), including `test_prepare.py`, which loads the worker with the video libraries gone; the reader bake-off below. |
| What is skipped | Password fields; six password managers, System Settings, sign-in dialogs, the lock screen and Hippocampus itself, by bundle ID; private browser windows that show it; 18 bank and sign-in addresses; four secret shapes, checked three times. | `SuppressionCascadeTests`, `BrowserPrivateWindowTests`, `BrowserWindowPrivacyTests`, `DenylistTests`, and the secret corpus `core/brain/fixtures/ocr-secret-corpus.json`, which the Swift and Rust checks both read. Real browsers' private windows: needs a person. |
| Encrypted memory | One SQLCipher database with its key in the login Keychain; screenshots sealed with AES-GCM. | `mci-brain` store tests, `KeychainDatabaseKeyResolverTests`, the `keyframe-codec-behavior` lane, `keychain_packaging_contract`. |
| Deleting | The last 24 hours or everything, with what was learned from it; the database is rewritten afterwards. | `delete_events_in_range_*` and `delete_event_*` in `core/brain/tests/sqlcipher_brain_store.rs`, `memory_projection.rs`, `understanding_store.rs`. In the app: needs a person. |
| Search | Exact words (FTS5) and meaning (Arctic Embed S on Core ML). | `hybrid_retriever.rs`, `recall_fusion.rs` and `retrieval_outcomes.rs` in `core/brain/tests`; the evaluations in [`docs/eval/`](eval/); `scripts/try-it.sh` run on Oct 16 (words only). |
| Ask | Shift twice or ⌃⇧Space opens it over any app. Matches appear as you type; Return asks for an answer with sources, this window first. | `AskPanelTests`, `AskShortcutTests`, `SoloKeyDetectorTests`, `CommandBarTests`. With a real keyboard: needs a person. |
| Answers and summaries | Apple Intelligence (macOS 26) or a model server on this Mac (Ollama, LM Studio). Without one, search still works. | `apps/mind` tests against a stand-in server (`LocalServerEngineTests`, `FakeModelServer`), and the `mind-without-foundation-models` lane. A real Ollama or LM Studio: not checked. |
| Overview and You | Your day as sessions, a Right now card, a summary, and what AI tools can be told about you, with Right and Forget. | The `recall-ui` tests and the `overview` tests in `apps/agent`. |
| AI tools | Connect AI Tools… registers the `hippocampus` MCP server with Claude Code and Codex. Each session can start with up to four lines of recent work and up to six things learned about you. | `mcp_server.rs`, `context_packet.rs`, `handoff.rs`, `what_is_sent.rs` and `client_registration_e2e.rs` in `apps/agent/tests`; the `menu-ai-connector`, `onboarding-ai-connector` and `session-context-behavior` lanes. A live Claude Code or Codex session on the 0.3.0 build: needs a person. |
| Menu bar, Pause, Stop Sharing, Quit | Four menu-bar pictures. Quit stops every process Hippocampus started; Stop Sharing turns remembering off; a crash stops the helper within 10 s. | `MenuBarStatusTests`, `StatusMenuModelTests`, `UserPauseControllerTests`, `CaptureStreamStopPolicyTests`, and the `quit-verifier-contract` lane on a stand-in app. In the real app: needs a person. |
| Setup | Four screens: Welcome, two permissions, the promises, and Try it. | The `apps/onboarding` tests. A first run on a new account: needs a person. |
| Updates | Check for Updates reads the newest GitHub release's `appcast.xml`, whose feed and DMG are signed with the release key. | `scripts/test-sparkle-publish.sh` (24 checks, judged by the app's own Sparkle) and `scripts/test-release-identity.sh`. No release is published yet, so until one is, Check for Updates says it couldn't check. |
| Install | `install.sh` checks the checksum, Apple's notarization and the Team ID before it copies the app. A Homebrew cask is ready in a local tap. | The `install-sh-fixtures` lane (14 checks on a fake release); on Oct 15 the same test passed 18 checks with the notarized 0.2.1 disk image. The cask passed `brew audit --strict` and `brew style` locally. From the public tap: needs a person, once the tap is pushed. |
| The release build | `scripts/release-0.3.0.sh` builds, signs, notarizes and checks the release; `--dry-run` does all but notarize. | The `release-app-gate`, `notary-log-contract`, `strip-release-binaries` and `release-contract` lanes. A dry run on Oct 15 at `088cd6a` exited 0. A notarized 0.3.0: not built yet. |
| The demo | `scripts/try-it.sh` makes a throwaway encrypted memory and searches it, without the Keychain. | Run on Oct 16 after `297a2f5`: exit 0, no Keychain prompt. |

## Measured

Reading quality, from `tools/ocr/screens/bench.py` on the recorded reads of
seven realistic windows and six decoys with made-up text, run on Oct 16 at
`b58b48b`:

| | Before 0.3 | 0.3.0 |
| --- | --- | --- |
| Interface text mixed into what you were reading | 94% | 21% |
| Text in reading order | 0.90 | 1.00 |
| Stray symbols per window | 14.7 | 1.0 |

The reader, from the [bake-off](../eval/ocr-bakeoff-2026-10-15.md) on a
MacBook Air M3 with made-up screens, Oct 15:

| | PP-OCR (shipped) | Apple Vision, tuned |
| --- | --- | --- |
| Lines read exactly, flat screens | 0.967 | 0.939 |
| Words, flat screens | 0.990 | 0.975 |
| CPU per read, median (p95) | 3.7 to 4.8 s (7.8 to 12.2 s) | 0.48 to 0.49 s |
| Energy per read, median | 3.8 to 4.2 J | 0.49 to 0.51 J |
| Peak memory, helper and reader | 1.3 to 1.7 GB | 0.30 GB |

Size. No build has both of 0.3.0's size cuts yet; the first release run
prints the real figures.

- With the reader that leaves out video, on a clone of a 0.3.0 candidate:
  disk image 180.3 MB (ULMO), app 370.2 MiB, of it the reader 243.1 MiB
  (bake-off).
- With stripped programs and the earlier reader, from the release dry run
  at `088cd6a`: disk image 198.1 MB, app 432.5 MB.

Not measured yet: CPU, memory, energy and disk over a whole working hour or
day. The goal is under 5% of the Mac. What bounds it today is in code: the
reader rests three times as long as each read took plugged in (busy at most
a quarter of the time), eight times on battery and sixteen in Low Power
Mode. The rest counts wall time, and a read uses about two cores (3.7 to
4.8 CPU-seconds over 1.9 to 2.6 s in the bake-off), so this bounds time, not
CPU share.

## Not checked yet

- A notarized 0.3.0 build. It needs the owner's Developer ID and notary
  profile (`scripts/release-0.3.0.sh`).
- A clean install on a new account, and an update from 0.2.1 that keeps the
  Keychain key.
- Quit and Stop Sharing in the real app, with nothing left running.
- The model process on a Mac running macOS 14 or 15. Its binary links
  Foundation Models weakly, so it should start there and say answers are
  unavailable.
- Answers from a real Ollama or LM Studio server.
- Each browser's normal and private windows, in front and behind.
- MCP clients other than Claude Code and Codex.
- Installing from the public Homebrew tap, and an update from the first
  published release.
- A working hour's footprint (above).

## Known limits

- Six password managers are skipped by bundle ID. Others are read like any
  app; `denylist.toml` keeps one out ([GUIDE](GUIDE.md#keep-an-app-out)).
- A one-time code or a bank alert shown in a window can be stored. The
  secret checks look for passwords, keys and tokens.
- A private browser window that shows no private marker is read.
- In Low Power Mode only the window in front is read.
- Connected AI tools can read your memory while Hippocampus is quit, and the
  app can't disconnect one ([how to](../PRIVACY.md#disconnecting-an-ai-tool)).
- Up to six things learned about you can start an AI session before you
  confirm them, at a model confidence of 0.5 or more. You shows each, and
  Forget removes it.
- Search results reach AI tools as plain text, and are marked "degraded",
  because no evidence verifier ships.
- Copy for your AI pastes 280-character previews, with some symbols written
  as HTML codes.
- The Overview lists searches only when it knows the pages' addresses:
  where Automation was already allowed, or with the browser extension.
- Memories saved before 0.3 keep the transcripts the old reader made.
  Read Again re-reads one moment that kept a screenshot.
- The agent still writes daily briefs that nothing in the window shows.
- No sync between Macs, and no Windows version.

## Checks to run

- `scripts/check.sh` runs every lane CI runs. `scripts/check.sh --help` lists
  them.
- `scripts/test-public-tree.sh` keeps private paths, old job titles, paid
  tiers and ruled-out claims out of the tree.
- `scripts/verify-quit-leaves-nothing.sh <app>` checks a built app leaves
  nothing running after Quit.
- `apps/hippocampus/Resources/build-app.sh` refuses to assemble a Developer
  ID signed app when this page's baseline is more than three commits behind
  `HEAD`. An ad-hoc development build (`--debug --development-ad-hoc`) builds
  from any commit. On a branch of your own, point the `Audited code
  baseline:` line at a recent commit you have checked before a signed build.

Older status notes are in this file's git history.
