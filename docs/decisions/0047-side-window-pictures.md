# ADR-0047: Pictures of windows beside the front one

- Status: Accepted (owner decision, 2026-10-19, SPEC section 6). Number
  provisional: the records of this round are numbered when they merge.
- Supplements: [ADR-0040](0040-whole-screen-background-capture.md), whose
  "No screenshot is retained for background windows" this replaces for
  people who allow it.

## Context

Hippocampus reads the text of every window a person can see (ADR-0040) but
kept a picture only of the window in front, so a chat or a reference page
beside the editor showed an app tile in History. The owner asked for "all
context on screen": the windows beside the front one should be remembered
as the front one is, pictures included, without growing what is read, what
is skipped, or how much disk Hippocampus takes.

## Decision

1. **The same frame, the same skips.** A picture of a side window is cut
   from the very display frame its text was read from, and only when that
   window's text cleared both privacy passes and its event validated (the
   cascade-twice path in `OCRPostAllowEmitter`). Everything never read
   stays out: excluded apps are removed from the pixels by the content
   filter, private and never-read browser windows are dropped after
   recognition, and a frame read under a stale filter is not read at all.
   A window whose text is suppressed never gets a picture.
2. **When a picture is kept.** All of: the window's text changed
   meaningfully since its last picture (three lines, 15% of the text, or a
   new title); at least 60% of it, and at least 200 × 120 points, is seen
   on that display; it is not a call app or page, nor a video player or
   site; at most one picture per window every two minutes (sooner for a new
   title), 30 an hour and 300 a day, and only when the picture changed
   visibly (a dHash distance of 12) or the last one is 30 minutes old; the
   budget is not full and the disk has 10 GB free (resuming above 12 GB);
   not in Low Power Mode, not on battery below 20%. The per-window ledger
   keeps hashes of lines and titles, never text, in memory only.
3. **Masking.** The crop is rounded inward to whole pixels inside the
   window; every window drawn in front of it (any layer), and any ordinary
   window of an excluded app, is masked rounded outward with a flat neutral
   fill (142, 142, 147), as are the window's rounded corners. Masks are
   applied to the full-size crop before scaling, so no covered pixel can
   bleed into the picture. The Dock's display-sized overlay and other
   excluded windows outside layer 0 are not in the pixels and mask nothing.
   Pictures that are almost one colour (protected video) are not kept.
4. **The sealed store path.** At most 1,600 pixels on the long edge, JPEG
   0.80 with every metadata segment removed, sealed with the same AES-GCM
   blob key and published by the same atomic, content-addressed store as
   front-window screenshots. The digest reaches the side moment
   (`screen_context`) only after the blob is durable, and the blob is
   removed if the moment is not written.
5. **Borrowing.** A front-window moment borrows only front-window
   screenshots, exactly as before side pictures existed. A side moment shows
   its own picture or the newest side picture of the same app and title
   (and page, when both name one) at most five minutes older, never a
   front-window screenshot.
6. **Budget and thinning.** Side pictures may use the person's 1, 2 or 5 GB,
   by default 2 GB or 2% of the disk if less; front-window screenshots are
   not counted and never thinned. The agent's retention worker thins them
   every 15 minutes and whenever the settings change: all from the last
   day, then one per window per 15 minutes (the one whose text changed
   most), per 2 hours after 7 days, per day after 30; over budget, the
   oldest days first down to one per window per day, then the oldest
   pictures, until under 90%. It writes a content-free
   `pictures-usage.json` (sizes, a count, the budget, on or off) beside the
   capture receipt; Preferences, Privacy and the helper read it.
7. **Consent and control.** New installs get side pictures with setup's
   first yes, which setup's promise covers; people who already use
   Hippocampus keep them off until they turn them on. The switch, the
   budget and Forget Pictures of Other Windows… live in `runtime.toml`,
   which the helper and the agent read at their next read: turning them off
   stops new pictures at once, without a restart. Only a regular settings
   file owned by the person, writable by no one else, can turn them on.

## Security review (ADR-0017 §7.4)

The purger's one new change, `retention_purger::clear_side_pictures`,
clears the screenshot reference of side moments that still hold exactly
the chosen picture, 256 to a transaction so ingest is never held for long,
then deletes blob files that no moment references. It inserts nothing, deletes no row, and never touches a
moment's text, caption or search, nor any front-window screenshot.
Retention and every forget remove side pictures with their moments, as
before.

## Consequences

- History, Web Pages, a Working On page's History and Ask {Tool} (when ticked
  by hand) show side pictures like any screenshot; a thinned moment shows
  its app tile, its text and caption unchanged.
- Disk: about 150 to 300 KB a picture, at most about 70 MB a working day at
  the caps; the budget is the backstop. A measured day on a test account
  belongs in `docs/STATUS.md` before launch.
- CPU: cropping, masking and encoding run off the capture queue, once per
  kept picture, inside the shared read budget.
- `PRIVACY.md` replaces "None of the other windows." with the paragraph in
  SPEC 9 row 151.

## Ratifier

The owner, through SPEC section 6 and the decisions of October 19, 2026.
