# ADR-0040: Whole-screen capture with per-window attribution

- Status: Accepted (owner decision, 2026-10-08)
- Amends: ADR-0031 (focused-window capture scope)

## Context

ADR-0031 limited capture to the focused window after a display-wide capture
filed text from Activity Monitor, a dashboard and a mail client under
`com.apple.Safari`, and later System Settings text under another app. The
fault was attribution: text from several windows reached the brain under the
focused app's identity, and the bundle-keyed privacy rules downstream acted on
the wrong identity.

The owner asked for the whole screen to be remembered, not only the focused
window: reference documents on a second display, a chat beside the editor.

## Decision

Keep the focused-window stream exactly as ADR-0031 built it, and add a
separate, low-rate stream per display for everything else:

1. **Exclusion at the source.** Each display stream's content filter removes,
   before any pixel is produced: the built-in sensitive apps (password
   managers, Keychain Access, System Settings, SecurityAgent and
   UserNotificationCenter), every browser (a background browser window cannot
   be confirmed non-private, so browsers stay with the focused path, which
   confirms the window first), notification banners
   (`com.apple.notificationcenterui`, which show one-time codes), Hippocampus
   itself, and every app on the owner's denylist. The filter names running
   processes, so before each read the helper checks every visible window of
   an excluded app against the processes the filter removes. An app that
   launched or relaunched since is in the pixels: the read is skipped, the
   filter is rebuilt, and reads resume only after the frames queued under the
   old filter have drained. Such a window can never own a line either.
2. **Attribution by geometry.** A display is read once; each recognized line
   is assigned to the topmost window that is in the pixels at its centre,
   using the window server's front-to-back list taken with the frame. Lines
   are dropped when that window is the focused one (its own stream reads it),
   is not an ordinary window (menu bar, Dock, panels), is denied by title
   (private windows) or by app, is smaller than 80 points, or when no window
   owns the point. No text crosses from one window's event into another's.
3. **Same privacy passes per window.** Each window's lines go through the same
   raw and compacted secret checks as focused text before anything leaves the
   helper. A display is not read while secure text entry is active anywhere.
4. **Its own message and source.** Background text is sent as
   `ContextOCREvent` (0x0041, the `OCREvent` layout) and stored with source
   `screen_context`. Episode segmentation does not treat it as a switch of
   focused work. No screenshot is retained for background windows.
5. **Cost bound.** A display stream runs at one frame per two seconds; a
   display is read at most every 15 seconds, only when its text visibly
   changed (the text-change thumbnail), and not while the user is idle.

Whole-screen capture is on by default. `defaults write ai.hippocampus
WholeScreenCapture -bool NO` (or `MCI_WHOLE_SCREEN=0`) keeps capture to the
focused window.

## Consequences

- Visible, unfocused windows become searchable under their own app and title.
- Browser windows remain focused-only, and their page text continues to come
  from the extension.
- Attribution depends on the window list matching the frame. Windows that move
  during the read can misplace a line at their edge; because exclusion happens
  at the source, such a line can only come from an app that was allowed to be
  in the pixels.
- The live-capture overlap qualification (`scripts/run-live-capture-overlap.sh`)
  qualifies the focused-window stream and runs with `MCI_WHOLE_SCREEN=0`, so
  its "background token absent" check keeps its meaning. Background
  attribution is pinned by `BackgroundCapturePolicyTests`.
