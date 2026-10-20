# apps/onboarding/BEST_PRACTICES.md

Subtree invariants for the onboarding SwiftUI app. Read the
top-level `BEST_PRACTICES.md` first; this file adds onboarding-
specific contracts derived from PR #83 and ADR-0017.

## Purpose

Setup is five screens (Welcome, What you get, Permissions, Promise,
Try it) and the panels the app opens by route. It is the ONLY place where the
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
   key monitor; the app does. Setup reads the Ask key preference
   (`AskShortcutLabel`) to name the key, and its key picker (Change…
   on the Accessibility row, SPEC-DELTA 7) writes the person's choice
   to the app's own preference and tells the app
   (`SetupAskKeyWriter`); nothing else writes it. Fn (Globe) is taken
   only after its checks, and over another app only on the person's
   Use Fn click. The checks read apps' bundle ids, macOS's Globe key
   setting and the I/O Registry's keyboard properties: no keyboard is
   opened, so no Input Monitoring prompt can show.

5. **Ask for Screen Recording from a child process only.** The
   onboarding window never calls `CGRequestScreenCaptureAccess()`:
   macOS may end the process that asked once the person allows it.
   `onboarding --tcc-request screen-recording` asks from a fresh copy
   of the binary that then exits, and `--tcc-probe screen-recording`
   checks from a fresh copy, whose answer may only turn a row on
   (`ScreenRecordingProbe.swift`). Tests use injected stand-ins and
   never touch the real permission database.

6. **Copy is security review-adjacent.** Permission copy and the Promise set
   the person's expectations about what is read and kept. Every
   string lives in `OnboardingCopy`, and every claim there is checked
   in code first (`scripts/test-onboarding-product-truth.sh` holds the
   consent claims). Surface any wording edit in the PR body.

7. **Views decide nothing.** A screen draws what the kit decided
   (`TryItPresentation`, the row states, `WelcomeDemoScript`,
   `OnboardingCopy`), so the tests and the preview renderer see what a
   person sees. After a change, render every screen off screen and look
   at it: `HIPPOCAMPUS_RENDER_ONBOARDING=<dir>` on a debug build writes
   each screen and state to a PNG and exits before any window exists.
   Add `HIPPOCAMPUS_RENDER_DEMO_STEP=<seconds>` to also write Welcome's
   demo frame by frame, to check its pace.

8. **Demos are made up; Try it is real.** Welcome's demo and What you
   get draw `OnboardingCopy.Demo` only: they never read memory, list a
   window or show the person's screen. Try it is the one screen that
   reads the person's real window, and only after consent, through the
   app like any other read: never-read apps, the person's exclusions,
   private browser windows and password fields are skipped, and the
   screen says so (`ReadRules`, copied from the helper and held to it by
   `CaptureListParityTests`). Its tests use made-up windows.

## Common mistakes

- Storing flow progress in `@State` (dies on quit) instead of
  through OnboardingKit's persisted state machine.
- Calling a real `CGRequest*Access` in a view or a view model,
  instead of through the `--tcc-request` child.
- Writing the consent file anywhere but `startRemembering`, or
  letting `advance()` or `goTo` pass Promise on a first run.
- Showing anything real in a demo or a render. The person's own window
  belongs on Try it alone, at runtime.

## Reference chain

- `../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — target map and edit rules.
- `../../docs/decisions/0017-phase-4-privacy-controls-onboarding-ux.md`.
- `../../docs/design/tcc-denial-recovery.md`.
- `../../docs/research/2026-07-12-onboarding-audit.md`.
