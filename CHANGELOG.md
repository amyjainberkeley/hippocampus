# Changelog

User-facing changes to Hippocampus are recorded here. Internal implementation
commits are intentionally omitted from release notes.

## [Unreleased]

## [0.3.0] - 2026-10-13

### Ask

- Press Shift twice anywhere and Ask drops from the menu bar. ⌃⇧Space works too, and Preferences offers right Shift, right ⌘ or right ⌥ instead.
- Ask is one field. Type to find anything you have seen, by meaning and by exact words, or press Return for an answer with its sources, this window first.
- History lives under Ask’s field, one day at a time, with clock times and Show Earlier.
- The window no longer has a popup of its own, and the Go menu’s keys work.

### Overview and You

- The window has three places, Overview, Ask and You, with the hi mark at the top and, at the bottom, whether Hippocampus is remembering.
- Overview shows your day as a strip of sessions coloured by kind. Hover to see a session’s screenshot, click to see what it held, and use the arrow keys to move between sessions.
- The Right now card shows what you’re working on, with Copy for your AI and the exact lines a connected AI already has. With no AI tool connected, it offers Connect.
- The day’s summary, written on this Mac, says what you worked on, in order, and what you looked up. It never guesses how long something took, gives no advice, and never calls you distracted, stuck or productive.
- Overview works without Apple Intelligence.
- You shows, in the exact words, what your AI can be told about you. Mark each item Right or Forget, with Undo, and open Why to see where it was learned.
- Show in History opens a session in Ask, and a session listed under You opens on Overview.
- Copy for your AI on a session copies that session’s own moments, and nothing learned about you.
- A finished session’s button opens the app it was mostly in.
- A moment saved without a screenshot shows its app’s icon instead of an empty picture.
- The privacy page shows storage as Text and Screenshots, names apps by their names, and no longer has buttons that did nothing, or a price.
- The old Today, Sessions, input chart, timeline strip and in-window Settings views are gone.

### Reading

- New moments keep what you were reading first. Tabs, sidebars, menus and status bars come after it, and nothing is dropped.
- A moment opens the way the window read: code keeps its indentation and chats keep their order. Tabs, sidebars and menus sit under “Also in this window”.
- Text from windows with side-by-side panes no longer runs across the panes.
- Line numbers, toolbar icons read as letters, and a window’s bars no longer open its text.
- When only part of a window was seen, nothing in it is set aside unless it sits at the window’s top or bottom edge.
- Browsers are read like every other window. No extension and no Automation prompt are needed.

### Privacy and control

- The menu-bar icon is the new hi mark. A solid dot means it is remembering. No solid dot means it is not.
- The menu is short: Remembering, Paused, Off, Needs permission, Not saving or Couldn’t stop, each with one button that acts.
- Under Remembering, the menu says when it last saved, for example “Last saved 8s ago”.
- Skipping a window for privacy shows “Skipping this window” once the skip has held, not “Not saving”. Only a password field shows the hollow dot.
- Private browser windows are skipped when they show they are private: a private title, or the private badge in the window’s top bar.
- Sign-in and bank sites stay never read, even when their address shows only in the address bar.
- Hippocampus never asks for Automation. It uses Automation only where you already allowed it.
- Every saved moment passes three checks for passwords and keys: the text as read, the page in reading order, and the exact text saved.
- Quit stops everything Hippocampus started, including Ask and its windows, and waits until they have exited.
- Stop Sharing always turns remembering off. Hippocampus stays off, even after a restart, until you turn it on, and says when you stopped it.
- A pause is kept across restarts and says since when.
- Turning remembering off shows Off only once it has really stopped.
- If Hippocampus is force quit or crashes, it stops reading the screen within about 10 seconds. Anything left reading is stopped at the next launch.
- Reset Permissions… resets only Hippocampus’s permissions, not every app’s.
- Hippocampus opens its window only when you open it. A launch at login, after an update or after a restart stays in the menu bar.
- ⌘Q quits and ⌘, opens Preferences whenever Hippocampus is in front.

### AI tools and models

- Connect AI Tools… connects Claude Code and Codex in one step.
- Your AI starts each session with the same recent work and things about you that the You page shows, word for word.
- AI tools are no longer sent notes about pauses or input counts.
- Context copied for your AI has no status lines, and each source says when and where it was seen.
- Answers and summaries without Apple Intelligence (beta): Hippocampus uses a model you run on this Mac with Ollama or LM Studio, and finds it without setup.
- Hippocampus talks only to a model server at 127.0.0.1, ::1 or localhost, follows no redirects, and never picks a model that runs in the cloud.
- With your own model, summaries and what Hippocampus learns are written while your Mac is plugged in. Ask answers on battery too.
- The part that writes answers now starts on macOS 14 and later.
- Apple Intelligence writes to you as “you”, in short plain sentences.
- Quitting Hippocampus stops the model at once, even while it is writing an answer.
- Unusual line breaks on screen no longer stall an answer until it times out.

### Setup

- Before setup is finished, the menu says “Not set up yet” and offers Finish Setup…. Nothing else turns remembering on.
- Setup no longer says browsers need the extension or a macOS prompt to be read. The Promise says private browser windows are skipped when they show they are private.
- Try it knows answers can come from a model on this Mac. With neither that nor Apple Intelligence, it says what answers need.
- The browser extension panel says what the extension adds: each page’s address and the text not on screen.

## [0.2.1] - 2026-10-08

### Remembering Again

- Screen memory records again. A safety check meant to catch hidden password
  fields was treating complex app windows (editors, chat apps, web pages) as
  unknowable and skipping every frame, and the on-device text reader was
  being handed screen images in a format it refused. Password managers,
  secure text entry, major sign-in and banking sites and private windows are
  still never recorded.
- New text is noticed: typing, new chat messages and edits are now read even
  when the rest of the window looks the same.
- The whole screen is remembered, not only the window in front. Other visible
  windows, including ones on a second display, are read every few seconds when
  their text changes and filed under their own app and title. Browsers,
  password managers, System Settings, notification banners and apps you deny
  stay out of those reads entirely. Turn it off with
  `defaults write ai.hippocampus WholeScreenCapture -bool NO`.

### Screen Text You Can Read

- Saved screen text now reads the way the screen does. Sidebars, chat panes
  and editor columns stay separate instead of being interleaved line by line,
  tables read row by row, and code keeps its indentation.
- Reading a screen takes about a second instead of six or more, so busy
  moments are no longer dropped while the reader catches up.

### Search And Install

- Searches from connected AI assistants return their results instead of an
  empty list labelled "degraded".
- Install with one line, `curl -fsSL https://github.com/amyjainberkeley/hippocampus/releases/latest/download/install.sh | sh`,
  or with Homebrew. The installer checks Apple's notarization and the
  developer signature before copying the app.

### Recall

- Change Recall's default shortcut to **Control–Shift–Space**, keeping it
  separate from a dictation app's Command–Shift–Space. Onboarding, popup and
  shortcut help show the new combination. Recall also remains accessible from
  the menu bar when another app owns the shortcut.

## [0.2.0] - 2026-09-27

### Handoff For Your Agents

- Preview a short, cited project handoff in Recall: where you stopped, next
  step, goal, decisions, what to avoid, files touched and git state. Choose a
  folder, inspect its sources and explicitly copy the packet. Desktop previews
  use existing memory without importing new session transcripts.
- Optionally import Codex and Claude Code sessions through explicit CLI setup.
  Desktop startup keeps background transcript imports off. Connecting an AI
  client registers its memory tools without installing importers or hooks.
- `mci-agent today` writes the day's standup across projects from
  transcripts, git and screen time.
- `mci-agent connect --all` installs the SessionStart hooks for both agents
  and a background refresh job; `disconnect --all` removes only those.
  `doctor` shows transcript freshness and when each agent last got a packet.
- One-command install (`scripts/install.sh`) that needs no screen permission.

### Screenshot text

- Improve small screenshot text with a bundled, offline open-source OCR model
  and preserve more Retina detail before recognition. No Python setup or API
  key is needed. Recognition remains fallible; original images remain evidence.
- Stop OCR subprocesses promptly when capture stops, and verify every bundled
  model and runtime dependency before assembling the app.
- Preserve sharper retained screenshots and zoom into the authenticated
  original. Re-read a saved screenshot locally, then inspect or copy the new
  reading separately; old transcripts and search results are not overwritten.
- Omit uncertain readings only after the complete raw text passes privacy
  checks. Bound model resizing for narrow captures, and fail an oversized
  recognition batch rather than publish an incomplete privacy review.

### Installation And Updates

- Replace the nested H icon with a simple brain mark across the Dock, menu bar,
  browser extensions and installer. Keep the light native presentation.
- Use a compact installer with fixed icon positions, clear installation and
  update instructions, and a separate Legal folder. Generate and verify its
  layout without driving Finder; do not silently ship a missing layout.
- Limit installer cleanup to the disk image mounted by that build. Leave other
  Hippocampus volumes alone, including installers already open on the Mac.
- Accept genuine macOS Quit requests through the existing verified recorder
  shutdown path. Keep accidental, unrequested termination blocked.
- Add a guarded whole-bundle swap utility for controlled owner upgrades. It
  preserves open read-only executable mappings and refuses a repeated or
  mismatched revision swap. Backup, writer shutdown and signature verification
  remain explicit prerequisites; this is not an automatic consumer updater.

### Work memory

- Separate Today, Search and History. Search starts with an empty search field;
  Sessions are grouped under History, and daily handoff remains an action.
- Put a measured-day distribution and foreground-app totals above resume points.
  Inspect the longest measured stretch and its intervals. Unknown time remains
  unknown; input and foreground state do not establish attention or task completion.
- Record short, privacy-gated activity intervals independently of screenshots in
  the encrypted store. Deletion and retention also govern these intervals.
- Center lexical search excerpts on matching words instead of always showing
  the beginning of the captured text. Retrieval order and source identities stay
  unchanged; stemming-only matches can still use the ordinary excerpt.
- Bound helper transport queues and stalled writes. A partial interrupted frame
  retires its transport instead of corrupting the following frame.
- Preserve the cached-screen retry across a bounded Vision quarantine wait.
  Keep recognition deadlines, cancellation and privacy checks unchanged.
- Reject backward-clock activity overlaps without interrupting unrelated screen
  ingestion. Keep storage failures fatal and rejected-activity counts separate.
- Reject corrections that would silently retire a broader-scope memory claim.
  Add a reproducible sequential policy evaluation with stale-state, deletion,
  project-isolation and malicious-content cases. This is not a real-agent benchmark.

### Daily review and handoff

- Open to a day-scoped review instead of another history feed. Search, History,
  and Sessions retain distinct destinations; existing Brief links remain usable.
- Inspect the last saved context, observed returns to an app, and gaps between
  available screen samples. Every observation links to its evidence. These are
  saved observations, not measured work time or claims that a task is complete.
- Keep current capture health and the daily handoff within reach at the top.
  Preview bounded source excerpts before copying or exporting, and recheck the
  source text and identity before anything is shared.
- Simplify the website around the actual Mac app, local memory, and selected
  context sharing. Keep installation, privacy and source details one click away.

### Everyday recall

- Start human search in Text mode. Related context is a separate choice; raw
  retrieval ranks are no longer presented as confidence percentages.
- Apply app, date and URL constraints before limiting Text results or filtered
  history. Calendar date ranges no longer include the next day's midnight.
  Unsupported Related filter combinations are explained rather than silently
  returning a misleading empty result.
- Read and copy the selected memory's stored text, not just its list preview.
  Reads are bounded at 128 KiB and clearly label truncated or unavailable text.
  The screenshot inspector preserves source citations in its full-text export.
- Remove the repeated filmstrip from every destination. Evidence panes adapt
  to a smaller window, with back navigation when there is not room for both.
- Keep contextual command updates from redrawing the entire workspace. Show
  readable text without its duplicated internal header; copy preserves the
  stored content and the screenshot export preserves its citations.
- Measure managed storage on request, including screenshot files and database
  sidecars. Show partial and unavailable measurements without guessing a total.
- Explicitly release a completed command's writer lock even when a duplicated
  descriptor remains; retain the daemon's protection through process teardown.

### Memory quality

- Save fewer duplicated OCR lines from overlapping recognition passes. Keep
  different positions and literal readings, check every original pass for
  secrets, then check the cleaned transcript before any text or image is saved.
- Read the latest source body for Daily Review before shortening its preview.
  Long internal headers no longer crowd out the useful text; day changes and
  unavailable or replaced evidence cannot reuse stale hydrated context.
- Recover more small text with bounded on-device OCR subregions inside the
  permitted focused window. Preserve complete OCR passes for secret detection;
  timeouts still discard all text, and capture coverage does not expand.
- Treat pasted `AND`, `OR`, and `NOT` as literal search terms. Keep internally
  generated fallback alternatives separate from user query syntax.
- Restore dictionary alias matches when semantic search is unavailable, without
  letting oversized optional aliases break the original search.
- Remove repeated browser menu lines from daily drafts and omit potentially
  clipped final lines whose missing qualifier could change their meaning.
  Original memory and source citations remain available.
- Show the focused-window capture area explicitly in Preferences.

### Onboarding

- Route Safari setup through the browser launcher and keep its concurrent
  completion outside the main-actor view model. Unit tests no longer open a
  real Safari window or schedule its Settings action.

### Capture reliability

- Record which stream operation failed and its bounded framework error code
  in the local diagnostic log, without screen text, URLs or error descriptions.
  Preserve terminal shutdown, automatic recovery, and explicit user-stop rules.
- Replenish automatic recovery after five minutes of a ready, committed capture
  run instead of exhausting ten retries across an entire day. Keep rapid-crash
  backoff bounded, preserve stop/pause/revocation guards, and report exhaustion
  explicitly in the menu-bar error state.
- Distinguish absent optional Accessibility labels from failed reads when
  checking ordinary text views. Keep real keyword-probe errors and secure-field
  detections blocking capture.
- Preserve failed and malformed Accessibility child reads through privacy
  checks. Incomplete bounded traversal remains unknown, never proof of safety.
- Diagnose unclassified Accessibility checks with rate-limited local error
  codes and outcomes, without logging screen text or fetching extra attributes.
- Bind captured frames to the focused-window stream generation so focus changes
  cannot attribute stale pixels to a newly focused app.
- Resolve public AX focus to one unique WindowServer surface twice, failing
  closed on ambiguous geometry or a same-application window switch.
- Retry static-window OCR after an empty, timed-out, or dropped recognition job
  without weakening focused-window or protected-surface privacy checks.
- Treat unexpected stream loss and failed teardown as terminal capture failures
  instead of leaving a healthy-looking helper with no live capture source.
- Keep qualification diagnostics content-free and fail the live gate when the
  capture helper cannot shut down cleanly.
- End live qualification through the packaged parent-lifetime lease and prevent
  resource samplers from holding capture pipes open during graceful shutdown.

### Product and demo truth

- Keep the Recall evidence-strip label readable beside real encrypted keyframe
  previews and verify the label in the canonical product screenshot.
- Resolve the verified repository-local Arctic model explicitly in disposable
  demos, require all 20 synthetic events to be embedded in semantic mode, and
  disclose degraded lexical-only mode when the artifact is absent.
- Strip text and EXIF metadata from canonical product captures and reject
  personal paths, email addresses, and common credential shapes during OCR
  asset verification.

## [0.1.0] - 2026-09-01

### Memory and recall

- Search local work memory with combined lexical and semantic retrieval, then inspect the source context behind each result.
- Review recent activity and open recall, privacy, and diagnostic surfaces from the native macOS app.
- Run OCR, embeddings, indexing, and retrieval on the Mac without sending captured content to a hosted inference service.

### Privacy and control

- Pause or resume capture and configure app and URL exclusions before content enters the memory pipeline.
- Manage local retention, export, and deletion controls for SQLCipher-backed memory storage.
- Retention removes expired database rows and compacts local storage; it does not claim range-key erasure.

### Integrations

- Ingest permitted browser context and explicitly allowlisted Mail or Messages content when the corresponding macOS permissions are enabled.
- Use bundled on-device models for semantic recall, entity recognition, and local brief generation when those surfaces are enabled.

### Preview limitations

- Live capture remains off by default until the user enables the persisted capture setting. Each change is accepted only after generation-bound helper readiness; physical-Mac TCC and sustained-capture verification are still pending.
- Runtime capture preferences are accepted only after whole-document TOML validation; malformed syntax, wrong types, and duplicate semantic keys fail closed.
- Quit and Quit-and-Restart now wait for verified helper and agent shutdown, escalating from TERM to KILL when needed, before the app exits or relaunches.
- Legacy `dev.key` custody migrates add-only into the macOS file Keychain and removes plaintext only after validation. Cross-version Developer ID ACL continuity for Hippocampus, the capture helper, the agent, and Recall remains an owner release gate.
- The Key Wrap Audit reports whether the item is readable without treating that read as proof of its access-control object. ACL inspection and signed cross-version continuity remain release gates.
