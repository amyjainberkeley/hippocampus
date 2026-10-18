# apps/onboarding/

The setup app the menu-bar app starts on first launch: five screens
(Welcome, What you get, Permissions, Promise, Try it) in one 760 by 560
window, and the panels the app opens by route after consent
(`hippocampus://setup/<panel>`).

- Welcome plays a live demo drawn from faithful copies of the app's own
  surfaces (`Sources/Onboarding/Demo/`), from made-up data only
  (`OnboardingCopy.Demo`). `WelcomeDemoScript` decides every frame.
- Try it reads the person's real window in front, the one behind setup,
  under the same rules as every read, and says plainly when it is
  skipped (`FrontWindow.swift`, `TryItViewModel`).

## Contents

- `Package.swift` — Swift-PM manifest. Two products:
  - `Onboarding` (executable) — the `@main` entry point, the window
    and the screens (`Slides/`), Welcome's demo (`Demo/`), plus a
    debug-only off-screen preview renderer.
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
