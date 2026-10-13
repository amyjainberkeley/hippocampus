# apps/onboarding/

The setup app the menu-bar app starts on first launch: four screens
(Welcome, Permissions, Promise, Try it) in one 760 by 560 window, and
the panels the app opens by route after consent
(`hippocampus://setup/<panel>`).

## Contents

- `Package.swift` — Swift-PM manifest. Two products:
  - `Onboarding` (executable) — the `@main` entry point, the window
    and the screens (`Slides/`), plus a debug-only off-screen
    preview renderer.
  - `OnboardingKit` (library) — view models, copy, the consent and
    resume stores and the permission checks, split for testability.
- `Sources/` — the two targets above.
- `Tests/` — XCTest suites (flow state machine, TCC-probe fakes).

## Related

- `../hippocampus/` — the parent shell that hosts this onboarding
  flow on first launch.
- `../../docs/decisions/0017-phase-4-privacy-controls-onboarding-ux.md`,
  `../../docs/design/tcc-denial-recovery.md`,
  `../../docs/research/2026-07-12-onboarding-audit.md`.

## When to edit here

The setup screens, their copy (`OnboardingKit/OnboardingCopy.swift`)
and the panels. Every permission check goes through an injectable
`TCCPermission`, so tests never touch the real permission database.
Retention policy semantics belong in `../../core/`.
