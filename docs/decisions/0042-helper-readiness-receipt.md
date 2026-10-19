# ADR-0042 — The capture helper's readiness receipt

- Status: Accepted (2026-10-19). Adds to ADR-0007 (the helper process boundary) and ADR-0040 (whole-screen reading).

## Context

The app starts the capture helper and the memory agent as a pair, one generation at a time, and must know three things before it takes a start for done: that the helper it is waiting on is the one it launched, whether it reads the screen, and whether it found a permission off as it started. A helper that finds Screen Recording or Accessibility off pauses on it. Until this record, that pause covered only the focused-window stream, and the app learned about it only from a stderr line read once a second, usually after it had already turned capture on.

## Decision

1. **Arguments.** The app passes `--readiness-file <path>` and `--generation <id>`, both or neither. The id is 1 to 128 ASCII letters, digits or hyphens. The file lives in the app's own temporary folder, `ai.hippocampus.helper-readiness/` (mode 0700).
2. **Publication.** The helper writes the receipt once, after its startup is done; for a capture generation, after the focused session's start returned, paused or not. The file is prepared off to the side and published with `link(2)`: it never replaces an existing receipt, a second publication fails, and the file is mode 0600. The helper exits nonzero when it cannot publish.
3. **Fields.** Exactly three keys:
   - `generation`: the id the app passed. The app refuses a receipt for any other generation.
   - `capture_enabled`: whether this generation reads the screen (`--capture`). The app refuses a receipt that disagrees with what it asked for.
   - `permissions_off`: the permissions the helper found off as it started, by surface name (`accessibility`, `screenRecording`), sorted, each once; empty without capture. Names only: the helper's API takes its `TCCSurface` enum, so no other text can be written there.
4. **What "paused" covers.** While any listed permission is off, the whole helper reads nothing: the focused-window stream and whole-screen reading (`PermissionGatedCapture`) both pause, and both start again only when every permission is back. Accessibility is answered live, so a helper can resume by itself; Screen Recording usually cannot, because a process's own answer stays "no" after the person allows it.
5. **What the app does with it.** A start whose receipt names a permission does not land, whichever change it serves: Turn On stays off with "Needs permission"; an ordinary start, a resume or a restart ends with "Needs permission" and nothing left running. Remembering never runs with a permission off; a run whose helper reports one off on stderr ends too. Since a fresh helper is the only reliable judge, every look (the menu opening, the app becoming active) starts a fresh one while remembering is on, and the app watches its own Accessibility trust to look again when it comes back.
6. **Compatibility.** A receipt without `permissions_off`, or with `null` there, reads as none off (an older helper). Any other shape fails readiness. A name the app does not know fails the start rather than read as none off, so a helper that monitors a new surface can never turn capture on behind an app that cannot name it; a test pins the helper's surface names to the app's.
7. **Lifetime.** The app removes the receipt when it stops the generation.

## Consequences

- Positive: the app decides from the receipt, at readiness, instead of racing a once-a-second stderr read; the status never says "Needs permission" or "stopped remembering" while anything reads.
- Positive: the receipt is content-free by type, not by caller discipline.
- Negative: a person who allows Screen Recording without macOS's Quit & Reopen needs a look (opening the menu is enough) before remembering starts again.
- The release fixture (`HelperReadinessBehavior`) checks the keys, the order and the mode of a capture receipt with permissions off; the live overlap run stops by name on a helper that started paused.

## References

- ADR-0007, ADR-0040.
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/HelperReadinessReceipt.swift`, `PermissionGatedCapture.swift`.
- `apps/hippocampus/Sources/HippocampusKit/SupervisorProcessRuntime.swift` (`permissionOff(inReadiness:for:)`), `ProcessSupervisor.swift`.
