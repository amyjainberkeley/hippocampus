# apps/onboarding/

The onboarding SwiftUI app — a 5-step TCC walkthrough + "What MCI
Sees" trust panel + retention-policy UI scaffold. Phase 4 P4.2
(ADR-0017 §2).

## Contents

- `Package.swift` — Swift-PM manifest. Two products:
  - `Onboarding` (executable) — the `@main` `App` with a
    `NavigationStack` flow.
  - `OnboardingKit` (library) — view models + TCC-probe protocol
    stubs, split for testability.
- `Sources/` — the two targets above.
- `Tests/` — XCTest suites (flow state machine, TCC-probe fakes).

## Related

- `../hippocampus/` — the parent shell that hosts this onboarding
  flow on first launch.
- `../../docs/decisions/0017-phase-4-privacy-controls-onboarding-ux.md`,
  `../../docs/design/tcc-denial-recovery.md`,
  `../../docs/research/2026-07-12-onboarding-audit.md`.

## When to edit here

Onboarding-flow screens, TCC-prompt copy, the "What MCI Sees" trust
panel, and the retention-policy scaffold. Real TCC probing wiring
lives in the Hippocampus supervisor — do NOT add live TCC calls
here (this app is designed to be exercisable without granting real
permissions). Retention policy semantics belong in `../../core/`.
