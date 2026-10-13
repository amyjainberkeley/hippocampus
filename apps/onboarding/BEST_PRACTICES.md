# apps/onboarding/BEST_PRACTICES.md

Subtree invariants for the onboarding SwiftUI app. Read the
top-level `BEST_PRACTICES.md` first; this file adds onboarding-
specific contracts derived from PR #83 and ADR-0017.

## Purpose

Setup is four screens (Welcome, Permissions, Promise, Try it) and
the panels the app opens by route. It is the ONLY place where the
person allows Screen Recording and Accessibility, and the only place
consent is given. A bug here can strand the person in a
half-permissioned state that produces silent capture failures later.
Rules below encode the resume-across-quit contract, the single
consent click, and how permissions are asked.

## Rules

1. **Resume-across-quit is a hard contract.** If the user quits
   the app mid-onboarding, the next launch MUST resume at the same
   screen. `OnboardingFlowViewModel` saves the screen's route name
   (`.onboarding-state`) on every move before consent, and clamps it
   at start: Try it needs consent, Promise needs both permissions.
   Once consent exists the resume point is cleared and never read, so
   setup shown again starts at Welcome rather than on Try it, which
   has no Back. A panel keeps its state in memory and never moves the
   resume point. Never store the screen in an ephemeral `@State` that
   dies with the view.

2. **TCC: never kill the process to prompt again.** If the user
   denies Screen Recording, DO NOT `exit(0)` to force a re-prompt.
   Show the deferred-permission recovery UI (`docs/design/tcc-
   denial-recovery.md`) and let the user return to the step from
   System Settings. Killing the process loses onboarding state.

3. **Both permissions, then one consent click.** Screen Recording
   and Accessibility are both required, shown at once, and Continue
   stays off until both are on. "Allow" raises macOS's prompt only;
   a row waits until the person comes back to the window, and one
   refresh decides. Consent is the click on Start Remembering:
   `startRemembering(keyReady:)` is the only code that writes
   `.onboarding-complete`, with the open-at-login choice. A
   permission it finds off sends the person back to Permissions.

4. **Setup registers no key.** Onboarding never installs a hotkey or
   key monitor; the app does, after consent. Setup only reads the
   Ask key preference (`AskShortcutLabel`) to name the key.

5. **Ask for Screen Recording from a child process only.** The
   onboarding window never calls `CGRequestScreenCaptureAccess()`:
   macOS may end the process that asked once the person allows it.
   `onboarding --tcc-request screen-recording` asks from a fresh copy
   of the binary that then exits, and `--tcc-probe screen-recording`
   checks from a fresh copy, whose answer may only turn a row on
   (`ScreenRecordingProbe.swift`). Tests use injected stand-ins and
   never touch the real permission database.

6. **Copy is CSO-adjacent.** Permission copy and the Promise set
   the person's expectations about what is read and kept. Every
   string lives in `OnboardingCopy`, and every claim there is checked
   in code first (`scripts/test-onboarding-product-truth.sh` holds the
   consent claims). Surface any wording edit in the PR body.

7. **Views decide nothing.** A screen draws what the kit decided
   (`TryItPresentation`, the row states, `OnboardingCopy`), so the
   tests and the preview renderer see what a person sees. After a
   change, render every screen off screen and look at it:
   `HIPPOCAMPUS_RENDER_ONBOARDING=<dir>` on a debug build writes each
   screen and state to a PNG and exits before any window exists.

## Common mistakes

- Storing flow progress in `@State` (dies on quit) instead of
  through OnboardingKit's persisted state machine.
- Calling a real `CGRequest*Access` in a view or a view model,
  instead of through the `--tcc-request` child.
- Writing the consent file anywhere but `startRemembering`, or
  letting `advance()` or `goTo` pass Promise on a first run.

## Reference chain

- `../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — target map and edit rules.
- `../../docs/decisions/0017-phase-4-privacy-controls-onboarding-ux.md`.
- `../../docs/design/tcc-denial-recovery.md`.
- `../../docs/research/2026-07-12-onboarding-audit.md`.
