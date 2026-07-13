# apps/onboarding/BEST_PRACTICES.md

Subtree invariants for the onboarding SwiftUI app. Read the
top-level `BEST_PRACTICES.md` first; this file adds onboarding-
specific contracts derived from PR #83 and ADR-0017.

## Purpose

The onboarding flow is the ONLY place where the user grants (or
declines) each TCC permission. A bug here can strand the user in a
half-permissioned state that produces silent capture failures
later. Rules below encode the resume-across-quit contract, the
deferred-permission choreography, and the hotkey-earning pattern.

## Rules

1. **Resume-across-quit is a hard contract.** If the user quits
   the app mid-onboarding, the next launch MUST resume at the same
   step. Flow state persists via the OnboardingKit state machine;
   never store step index in an ephemeral `@State` that dies with
   the view.

2. **TCC: never kill the process to prompt again.** If the user
   denies Screen Recording, DO NOT `exit(0)` to force a re-prompt.
   Show the deferred-permission recovery UI (`docs/design/tcc-
   denial-recovery.md`) and let the user return to the step from
   System Settings. Killing the process loses onboarding state.

3. **Deferred-permission choreography.** Steps that require a TCC
   prompt MUST NOT block the flow if denied. The user proceeds
   with a recorded "deferred" marker; capture stays off for that
   surface until they grant permission later from Settings.

4. **Hotkey-earning pattern (PR #83).** Global hotkeys (e.g.,
   ⌘⇧M for recall) are registered only AFTER the user completes
   the "What MCI Sees" trust panel. Registering earlier violates
   the informed-consent posture that ADR-0017 codifies.

5. **No real TCC calls in this target.** Per README, TCC probing
   lives in the Hippocampus supervisor. This app exercises TCC via
   protocol stubs so it runs on a dev machine without prompting.
   Live `CGRequestScreenCaptureAccess()` calls belong upstream.

6. **Copy is CSO-adjacent.** TCC-prompt copy and the trust-panel
   text set user expectations about what is captured. Changes are
   Track B — surface any wording edit in the PR body.

## Common mistakes

- Storing flow progress in `@State` (dies on quit) instead of
  through OnboardingKit's persisted state machine.
- Calling a real `CGRequest*Access` in a view — bypasses the
  supervisor and produces prompts the state machine can't track.
- Registering the recall hotkey in `App.init` before the user
  has seen the trust panel (regression risk called out in PR
  #83).

## Reference chain

- `../../BEST_PRACTICES.md` — MCI-wide invariants (root).
- `./README.md` — target map and edit rules.
- `../../docs/decisions/0017-phase-4-privacy-controls-onboarding-ux.md`.
- `../../docs/design/tcc-denial-recovery.md`.
- `../../docs/research/2026-07-12-onboarding-audit.md`.
