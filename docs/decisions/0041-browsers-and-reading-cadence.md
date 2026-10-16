# ADR-0041: Browsers are read like other windows, and reading follows a budget

- Status: Accepted (owner decisions of 2026-10-11 to 2026-10-13, recorded 2026-10-15)
- Supersedes: ADR-0040 §1 where it removes every browser from the display streams, and ADR-0040 §5 (cost bound)

## Context

ADR-0040 kept every browser out of the whole-screen streams, because a browser window behind others could not be confirmed non-private, and it read each display at most every 15 seconds.

Both choices cost too much in use. Without browsers, much of a working day was missing. And the reader cost more than planned: on battery the OCR worker drew about 340% of a core re-reading whole displays every 24 seconds (`c3417fd`), and during a video call on mains power it sat at 86% of a core, at about 13 CPU-seconds a read (`9236dd4`).

The owner decided that browsers are read like every other window, with no extension and no Automation prompt, and that private windows are skipped (`ba5fa9b`).

## Decision

1. **Browsers are read.** They stay in the display streams, and the window in front needs no positive check. A browser window is skipped when it shows that it is private: a private title, or a private badge or private words in its top 120 points, read after recognition and before anything is stored. A window seen to be private stays private for its life. The sign-in and bank sites, and the person's own URL rules, apply to the address read in the top bar and to a title that is an address (`7dc658c`). Automation is used only where the person already allowed it, and never prompted for.
2. **The window in front** is read when its text changes, at most every 3 seconds, and every 15 seconds once its picture keeps moving. On battery every interval doubles, and in Low Power Mode it is four times as long (`FocusedReadPacing`).
3. **Other windows** are read when their text changes outside the window in front: a display at most every 30 seconds plugged in and every 60 on battery, and not at all in Low Power Mode. Only the windows that changed are read (`CapturePower.displayReadInterval`, `BackgroundCaptureSession`).
4. **The reader rests.** After each read, no read starts for three times as long as that read took plugged in, eight times on battery and sixteen in Low Power Mode, at most two minutes. So the reader is busy at most a quarter of the time on mains and a ninth on battery, whatever is on screen. The window in front and the displays share this one budget (`CaptureReadBudget`).

## Consequences

- A private window that shows no marker is read. Skipping a browser window unless it is confirmed non-private would miss most browsing; the trade-off is stated in PRIVACY.md and SECURITY.md.
- In Low Power Mode Hippocampus remembers only the window in front.
- Text on another display can wait up to a minute on battery before it is read, and is missed if it changes and goes within that time.
- The budget counts wall time, not CPU time. A read that uses two cores rests for three times its wall time, so the share of CPU can be higher than the share of time. A CPU-time budget, and a measured hour, are open work ([STATUS](../STATUS.md)).
- `FocusedReadPacingTests` pins the intervals and the rests, and `CapturePowerTests` pins the display intervals.
