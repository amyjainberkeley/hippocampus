# ADR-0045: Working On is made from window titles, by rules, with no model

- Status: Accepted (2026-10-19). Numbered when the round merged (the records of 2026-10-19 are 0044 to 0050).
- Ratifier: Amy, October 19, with the prototype ("absolutely everything is perfect") and SPEC-DELTA 2 to 4: a little screenshot for each item, Resume, and a page with "full context … in great depth".

## Context

People come back to their computer asking "where was I?" by project: the code they were changing, the plan they were writing, the design they were reviewing. Hippocampus kept every moment, but nothing grouped them by what the person was working on. A model could guess project names, but a guessed name can be wrong, private or unsettling, and it changes from run to run.

## Decision

1. **One function says what a window is about** (`core/brain/src/subject.rs`). From the app, the window's title and its address it returns a kind (code project, document, design, spreadsheet) and a name in the window's own words: an editor's folder, a document's title without the app's suffix, a design file's name. Generic titles ("Untitled", "New Tab"), an AI tool's own terminal ("Claude Code", "codex"), chats, mail and messages name nothing. A name that touches a sensitive area by the shared list is kept off the sidebar until the person shows it.
2. **Membership is time in front, on days of use.** An item joins the sidebar once its windows were in front for 30 minutes in all within the last 14 days of use (a day with anything saved, so a week away doesn't empty the list), is ordered by its time in the last 7 days of use, and leaves after 14 days of use without it. It stays on Working On's page while any of its moments are kept.
3. **One agent read.** `mci-agent work --json` answers with the items, the pages read (Web Pages), which item a moment belongs to, the files, what was seen alongside (ranked so what is open beside everything doesn't win), the folder a code project seems to be in, and the newest moment with a kept screenshot for the sidebar's thumbnail. `--item` pages one item's moments; `resume-plan` rebuilds its last session as a list of things to reopen (SPEC-DELTA 3).
4. **Ids are keyed hashes.** An item's id is an HMAC-SHA256 of its kind and name, keyed by the memory's own key (`keyed_id` in `core/src/crypto/db_key.rs`), so the window's settings, links and routes carry no project name, and an id means nothing on another Mac.
5. **No model is asked.** The names are the person's own words, the same on every read, testable with fixtures, and cheap enough to read every two minutes.

## Consequences

- A renamed document becomes a new item; joining it to its earlier name by its address is not done yet.
- Names are compared lower-cased with invisible characters removed, not yet Unicode-normalized.
- After a forget, older sessions without notes lose their time; only the last 36 hours are measured again from the moments until notes are rewritten.
- The 90-day read was measured at 375 ms in a debug build; a release build's time is not measured.
- Tests: `core/brain/tests/subject.rs` (every title fixture, the never-names, a fuzz test), `apps/agent/tests/work_cli.rs`, and in the window `WorkReaderDecodingTests`, `WorkingOnModelTests`, `WorkingOnItemModelTests`, `WebPagesModelTests`, `LookedUpModelTests`, `ResumeSheetModelTests`.
