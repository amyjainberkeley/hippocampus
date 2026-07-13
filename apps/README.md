# apps/

All shipping app targets: the Rust agent binary, the SwiftUI menu-bar
shell, the recall UI, the onboarding flow, and the browser native-
messaging host. Each app is a thin shell — the substance lives in
`../core/` and `../adapters/macos/`.

## Contents

- `agent/` — `mci-agent`, the Rust binary that supervises the
  capture helper, owns the per-device id, and runs the IPC select!
  loop.
- `hippocampus/` — the main SwiftUI Mac app shell (menu-bar
  `MenuBarExtra`). Supervises `MCICaptureHelper` + `mci-agent` as
  child processes.
- `recall-ui/` — the read-only recall SwiftUI app (Phase 3, ADR-0016
  §6). Links `../adapters/macos/mci-brain-ffi/`.
- `onboarding/` — SwiftUI 5-step TCC walkthrough + "What MCI Sees"
  trust panel (Phase 4, ADR-0017).
- `hippocampus-native-host/` — Rust native-messaging host for the
  browser extensions in `../extensions/`.

## Related

- `../core/` — the portable Rust core these apps link.
- `../adapters/macos/` — the macOS adapters these apps depend on.
- `../BEST_PRACTICES.md` — errors surface, never fall back.

## When to edit here

App-shell / lifecycle concerns: process supervision, menu-bar
plumbing, SwiftUI navigation, TCC-prompt copy, native-messaging
framing. If the change is about capture pipeline, brain, crypto, or
IPC wire format, it belongs in `../core/` or `../adapters/macos/`,
not here — apps must stay thin.
