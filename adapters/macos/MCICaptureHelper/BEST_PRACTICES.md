# adapters/macos/MCICaptureHelper/BEST_PRACTICES.md

Subtree invariants for the signed macOS capture helper. Read the
top-level `BEST_PRACTICES.md` first; this file adds capture-specific
rules that flow from ADR-0007 and ADR-0013.

## Purpose

MCICaptureHelper is the only process in the system that holds a
live ScreenCaptureKit stream. Every frame and every piece of
metadata that leaves this process passes through the ADR-0013
sensitive-surface suppression cascade first. Bugs here can silently
route protected content to the brain — the highest-severity failure
mode in MCI.

## Rules

1. **TCC: never kill the process to "reset" state.** The user may
   revoke Screen Recording at any moment; the helper reacts by
   stopping the stream and surfacing a typed error to the agent
   supervisor. Do NOT `exit(1)` on TCC changes — that produces a
   crash-loop the user cannot recover from without reinstalling.

2. **Cascade runs BEFORE IPC.** The full ADR-0013 cascade
   (denylist, secure-input probe, incognito hint, focused-window
   scope, screen-share leak detection) MUST evaluate before any
   frame or context payload is serialized to the wire. A frame that
   was captured and then discarded downstream is a leak.

3. **Screen-share leak detection is load-bearing.** If a Zoom/
   Meet/Teams share is active on the target display, capture MUST
   pause for the duration of the share, not merely redact. See
   `docs/research/2026-05-18-macos-secure-surface-detection.md`.

4. **Denylist enforcement is per-frame, not per-window-focus.** A
   denylisted app can briefly become frontmost during a window
   switch; a frame captured in that window is a leak. Check bundle
   ID on every frame, not just on focus change.

5. **Protected-set touch requires driver-CSO.** Changing the
   sensitive-surface list, the incognito heuristic, or the
   focused-window scope (ADR-0031) requires an explicit CSO note
   in the PR body per top-level rule 8.

6. **Wire format lives in `../../core/src/ipc/`.** Do NOT define a
   Swift-side struct that shadows the wire schema. Regenerate from
   the Rust source of truth or fail the build.

## Common mistakes

- Adding a new capture surface (e.g., a new context stream) and
  wiring it directly to IPC without running it through the
  cascade. The cascade is not optional per surface.
- Using `NSWorkspace.frontmostApplication` alone as denylist
  gate — misses the focus-transition race. Combine with the
  per-frame bundle-ID check.
- Copying the wire encoder into Swift for "convenience" — the
  Rust side changes without notice; drift produces silent data
  corruption on the agent.

## Reference chain

- `../../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — helper map and edit rules.
- `../../../docs/decisions/0007-macos-capture-separate-signed-helper-process.md`,
  `0013-native-grade-sensitive-surface-suppression.md`,
  `0031-focused-window-capture-scope.md`,
  `0014-fdpass-bindings-rustix-and-owned-surfacelease.md`.
