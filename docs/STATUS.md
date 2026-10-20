# Hippocampus Status

_Updated October 20, 2026, for the next release after 0.3.0._

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
| What is skipped | Password fields; six password managers, System Settings, sign-in dialogs, the lock screen and Hippocampus itself, by bundle ID; private browser windows that show it; 18 bank and sign-in addresses; secret shapes (labelled secrets, vendor API keys, tokens, card numbers, one-time codes) in a moment's text, title or address, checked three times on screen and again by the agent before it stores anything from any source, after an address loses its sign-in parameters. | `SuppressionCascadeTests`, `TitleAndAddressSecretTests`, `BrowserPrivateWindowTests`, `BrowserWindowPrivacyTests`, `DenylistTests`, the agent's `secret_gate`, ingest and import tests, and the corpora `core/brain/fixtures/ocr-secret-corpus.json` and `url-secret-params-corpus.json`, which the Swift and Rust checks both read. Real browsers' private windows: needs a person. |
| Encrypted memory | One SQLCipher database with its key in the login Keychain; screenshots sealed with AES-GCM. A key that ever sat in a file (`dev.key*`) is changed once, at the next start: database re-encrypted, every screenshot re-sealed, verified, then the old key and files deleted; it resumes after a crash and is undone on a failure. The data folder is left out of Time Machine unless Preferences includes it. | `mci-brain` store tests, `KeychainDatabaseKeyResolverTests`, the `keyframe-codec-behavior` lane, `keychain_packaging_contract`, `apps/agent/tests/key_change.rs` (a stop at every step, 20 real kills, a full disk, a locked Keychain), `KeyChangeAccountTests`, `MemoryBackupsTests`. On a real install: needs a person. |
| Deleting | The last 24 hours or everything, with what was learned from it; the database is rewritten afterwards and its log emptied. Delete Everything also deletes the key, so earlier backups and snapshots can't be read; a new key is made at once. | `delete_events_in_range_*` and `delete_event_*` in `core/brain/tests/sqlcipher_brain_store.rs`, `memory_projection.rs`, `understanding_store.rs`, `wal_truncated_after_deletion.rs`, the erase tests in `apps/agent/tests/key_change.rs`, `MemoryEraseTests`. In the app: needs a person. |
| History | Each moment leads with one short line saying what it was about, written on this Mac by Apple Intelligence or a model server, or made from its title, then its text without the window's tabs, address bar, bookmarks and side bars, which stay under Also in this window and in search. Older moments are cleaned and captioned in the background, only on a power cable while the Mac is idle. | `core/brain/tests/chrome.rs`, `caption.rs`, `reclean.rs` and `reading.rs`; `moment_readings_ffi.rs`; the `reclean_worker` tests in `apps/agent`; `MomentCaptionTests`; the mind's caption tests; renders of made-up windows. On a real memory: needs a person. |
| Search | Exact words (FTS5) and meaning (Arctic Embed S on Core ML). | `hybrid_retriever.rs`, `recall_fusion.rs` and `retrieval_outcomes.rs` in `core/brain/tests`; the evaluations in [`docs/eval/`](eval/); `scripts/try-it.sh` run on Oct 16 (words only). |
| Ask | Shift twice (or Fn, if chosen) or ⌃⇧Space opens it over any app, like Spotlight: as you type it finds Working On items, pages and moments; ↩ opens, ⌘↩ asks your AI tool, ⌥↩ resumes an item. Return on a question asks for an answer with sources, this window first. It never takes ⌘Space. When a known Fn app or macOS's Globe key setting holds Fn, Hippocampus says which and waits; only a tap of Fn alone counts, and the key monitor watches modifier keys only. | `AskPanelTests`, `AskPanelHandoffTests`, `AskShortcutTests`, `SoloKeyDetectorTests`, `FnKeyMonitorTests`, `CommandBarTests`. With a real keyboard: needs a person. |
| Answers and summaries | Apple Intelligence (macOS 26) or a model server on this Mac (Ollama, LM Studio). Without one, search still works. | `apps/mind` tests against a stand-in server (`LocalServerEngineTests`, `FakeModelServer`), and the `mind-without-foundation-models` lane. A real Ollama or LM Studio: not checked. |
| The window | A sidebar: Today, Working On, Library (History, Web Pages, Documents, Code, Conversations, Looked Up), About You, AI Tools and Privacy, with fixed keys ⌘1 to ⌘9. The field over every memory page searches by meaning, kept to the page with ⌘F. A line at the top of every page while remembering is paused or off; Pause, Resume and the forget hold go to the app over a private pipe. Light and dark. | `SidebarModelTests`, `SidebarHidesTests`, `StatusBannerTests`, `WindowChannelTests`, `ForgetCoordinatorTests`, `WindowContrastTests`, `NativeWorkspacePresentationTests`; the app's `WindowChannelServerTests` and `CaptureHoldTests`; off-screen renders of every page. On a real screen: needs a person. |
| Today and About You | Where you left off with its screenshot, the day's sessions, today's meetings when the calendar is on, what you looked up; what AI tools can be told about you, with Right and Forget. | `OverviewViewModelTests`, `TodayCardStateTests`, `TodayCalendarTests`, `NoCountingSentencesTests`, `UserModelViewModelTests`, and the `overview` tests in `apps/agent`. |
| Working On and Resume | Projects and documents named from window titles, by rules, once you spend 30 minutes on them in 14 days of use; a page for each with where you left off, files, pages seen alongside, meetings and its History. Resume lists what was open in the item's last session and opens only what you tick. | `core/brain/tests/subject.rs`, `apps/agent/tests/work_cli.rs`, `WorkingOnModelTests`, `WorkingOnItemModelTests`, `ResumeSheetModelTests`, `ResumePlanTests`. Resume opening real apps and tabs: needs a person. |
| Formatted text | A moment reads as headings, paragraphs, lists, code, terminal output and chat turns; Copy Text keeps the structure; older moments are made again in the background. | `core/brain/tests/reading_blocks.rs` and `reading_blocks_budget.rs`, `mci-brain-ffi/tests/event_reading_blocks.rs`, `ReadingBlocksDecodingTests`, `FormattedReadingSnapshotTests`. |
| Ask {your tool} | Ask Claude (or the last tool chosen) opens the tool with the message in its box; nothing is sent. One builder makes every message; the clipboard copy stays on this Mac, out of clipboard history, and clears after 2 minutes. | `apps/agent/tests/send_card.rs`, `AskAIButtonTests`, `SendCardClientTests`, `WindowHandoffDeliveryTests`, `AskPanelHandoffTests`. A real Claude, Codex, Cursor or ChatGPT opening with the text in its box: needs a person. |
| Calendar | Off until turned on. Then today's meetings over Today's day strip, a call named after its meeting, a project's meetings, and Ask's "When did I last meet with …?". Titles, times, calendar names and places only. | `CalendarPrivacyTests` in both apps, `SystemCalendarTests`, `CalendarQuestionTests`, `CalendarAttributionTests`. macOS's prompt on a signed build: needs a person. |
| Pictures of other windows | When a window beside the one in front changes its text, a picture of that window alone, masked to it, at most 30 an hour; never for calls, video or private windows. At most 2 GB (1, 2 or 5 GB in Preferences), older ones thinned first. Off for people upgrading until they turn it on. | `SideWindowPicturePolicyTests`, `WindowPictureCropTests`, `core/brain/tests/side_pictures.rs`, `moment_screenshots.rs`, `apps/agent/tests/side_pictures_retention.rs`, `brain_ingest_context.rs`. A working hour's disk and CPU: needs a person. |
| Demo Memory | A made-up week in its own folder, from Option-click on the hi menu or Preferences, under About; remembering is paused while it is in use. | The seeder's `demo_week` tests, the `swift-test-demo-memory` lane, `DemoMemorySwitchingTests`, `DemoMemoryTests`. In the signed app: needs a person. |
| AI tools | Connect AI Tools… registers the `hippocampus` MCP server with Claude Code and Codex. Each session can start with up to four lines of recent work and up to six things learned about you. Disconnect… and Disconnect All… in Preferences take out exactly what Connect added. | `mcp_server.rs`, `context_packet.rs`, `handoff.rs`, `what_is_sent.rs` and `client_registration_e2e.rs` in `apps/agent/tests`; the `menu-ai-connector`, `onboarding-ai-connector` and `session-context-behavior` lanes. A live Claude Code or Codex session on the 0.3.0 build: needs a person. |
| Menu bar, Pause, Stop Sharing, Quit | Four menu-bar pictures. Quit stops every process Hippocampus started; Stop Sharing turns remembering off; a crash stops the helper within 10 s. | `MenuBarStatusTests`, `StatusMenuModelTests`, `UserPauseControllerTests`, `CaptureStreamStopPolicyTests`, and the `quit-verifier-contract` lane on a stand-in app. In the real app: needs a person. |
| Setup | Five screens: Welcome with a live demo of Ask, Today and an AI tool from made-up data, What you get, two permissions, the promises, and Try it, which reads the window behind setup and shows what it read or why it was skipped. Screens slide the way you go; the key that opens Ask can be Fn. | The `apps/onboarding` tests and the off-screen renders (`HIPPOCAMPUS_RENDER_ONBOARDING`). A first run on a new account, and the demo's motion on screen: needs a person. |
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

A picture of a window beside the one in front takes about 48 ms for the
largest window (median, release build): about 1.5 s of CPU an hour at the
caps, counted against the reader's rest.

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
- A working hour's footprint (above), and the disk the pictures of other
  windows use over one.
- Asking macOS for the calendar from a signed build, from Preferences and
  from Today's Show Calendar.
- Resume and Ask {your tool} opening real apps, tabs and AI tools.
- Demo Memory in the signed app, and leaving it.

## Known limits

- Six password managers are skipped by bundle ID. Others are read like any
  app; `denylist.toml` keeps one out ([GUIDE](GUIDE.md#keep-an-app-out)).
- A one-time code with no keyword near it ("verification code",
  "passcode", "your code is" and the like) or a bank alert shown in a window
  can be stored. Card numbers that pass the Luhn check and codes next to such
  a keyword are dropped, as are labelled secrets, JSON web tokens, private
  keys and the API keys of Anthropic, OpenAI, GitHub, GitLab, Slack, Google,
  AWS and Stripe, wherever a moment comes from (`scripts/e2e-full.sh`, check
  c8; `apps/agent/src/secret_gate.rs`).
- A key in another shape, shown on its own with no label such as
  `api_key =`, can be stored.
- An address keeps every parameter whose name doesn't mark a credential
  (`access_token`, `code`, `key`, `sig`, `password` and the like are
  removed), so a token under another name can be stored with it.
- The text reader's ONNX Runtime 1.30 still contains Microsoft's telemetry
  client (audit check `net.binary`). The worker turns it off before ONNX
  Runtime loads and runs with the network denied (`sandbox-exec`), and a
  release stops if its worker starts any network request. Builds up to 0.3.0
  did neither: their worker posted to a Microsoft collector over HTTPS (four
  requests, about 45 KB, in one test run). They left
  `~/Library/Caches/hippocampus-ocr` and `~/Library/HTTPStorages/hippocampus-ocr`,
  which the app now deletes when it starts, and ONNX Runtime's own
  `~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime` (a
  device ID), which apps that use ONNX Runtime share, so Hippocampus leaves
  it.
- The database key is a login-Keychain item that never syncs, but no
  this-device-only class is set: it moves with a copied login keychain
  (audit check `custody.this-device`).
- A connected AI tool that was reading when you deleted everything keeps
  the deleted files open, and can read them, until it quits. A window opened
  by hand, not from the menu bar, deletes every moment but keeps the key.
- A page the Safari extension stages waits as plain text for up to a minute
  before it is forwarded or deleted.
- The window can delete the last 24 hours or everything, but has no button
  that forgets one moment; the reader it uses can.
- A private browser window that shows no private marker is read.
- In Low Power Mode only the window in front is read.
- Connected AI tools can read your memory while Hippocampus is quit, until
  you disconnect them ([how](../PRIVACY.md#disconnecting-an-ai-tool)).
- Up to six things learned about you can start an AI session before you
  confirm them, once the model's confidence is 0.75 or more and three
  moments on two different days show them; nothing about a sensitive area
  goes unless you confirm it. About You shows each, and Forget removes it.
- Search results reach AI tools as plain text, and are marked "degraded",
  because no evidence verifier ships.
- Copy for Your AI and Ask {your tool} send each moment's whole reading as
  Markdown, shortened evenly to fit the tool's message box.
- The Overview lists searches only when it knows the pages' addresses:
  where Automation was already allowed, or with the browser extension.
- Memories saved before 0.3 were read before windows were classified. Their
  tab strips, bars and side bars are set apart, but text the old reader ran
  together across columns is only partly separated. Read Again re-reads one
  moment that kept a screenshot.
- The agent still writes daily briefs that nothing in the window shows.
- No sync between Macs, and no Windows version.

## Checks to run

- `scripts/check.sh` runs every lane CI runs. `scripts/check.sh --help` lists
  them.
- `scripts/test-public-tree.sh` keeps private paths, old job titles, paid
  tiers and ruled-out claims out of the tree.
- `scripts/verify-quit-leaves-nothing.sh <app>` checks a built app leaves
  nothing running after Quit.
- `scripts/e2e-full.sh` is the full end-to-end test, a manual gate. It
  builds the development app and its disk image and checks them (mounted
  read-only: signatures, layout, architectures, usage strings), opens the
  app from the build under a throwaway home through the launch gate, sends
  made-up windows through the capture helper's pipeline into the agent, and
  checks the window's reads, search, Ask, the handoff packet, Resume's
  plan, the secret checks, forgetting, retention and uninstall. Then
  `scripts/audit-storage-security.sh` audits the home: ciphertext brain,
  WAL and screenshots, no plain text anywhere else, modes, key custody, the
  clipboard and the network (no-egress, `lsof` samples and the unified
  log). It needs an unlocked Mac and takes 20 to 40 minutes; every check
  prints PASS, FAIL, SKIP or PERSON. `--reference-dmg` also inspects a
  release-signed disk image. Without a GUI, `scripts/e2e-full.sh --headless`
  runs in the `e2e-full-headless` lane, and the audit's detectors run on
  made-up homes in `storage-audit-contract`. What only a person can check
  (Screen Recording and Accessibility, Shift twice, a notarized first open,
  a live Claude Code session) is the 10-minute check on a fresh account.
- `apps/hippocampus/Resources/build-app.sh` refuses to assemble a Developer
  ID signed app when this page's baseline is more than three commits behind
  `HEAD`. An ad-hoc development build (`--debug --development-ad-hoc`) builds
  from any commit. On a branch of your own, point the `Audited code
  baseline:` line at a recent commit you have checked before a signed build.

Older status notes are in this file's git history.
