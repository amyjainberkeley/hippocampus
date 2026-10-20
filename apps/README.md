# apps/

All shipping app targets: the Rust agent binary, the SwiftUI menu-bar
shell, the recall UI, the onboarding flow, and the browser native-
messaging host. Each app is a thin shell — the substance lives in
`../core/` and `../adapters/macos/`.

## Contents

- `agent/` — `mci-agent`, the Rust program that owns the memory: it
  stores what the capture helper sends, builds search data, sessions
  and what it learns, deletes what is past its keep date, and serves
  AI tools (`mci-agent mcp-serve`).
- `hippocampus/` — the main SwiftUI Mac app shell (menu-bar
  `MenuBarExtra`). Supervises `MCICaptureHelper` + `mci-agent` as
  child processes.
- `recall-ui/` — the window: Today, Working On, History and its lenses,
  About You, AI Tools and Privacy. Links `../adapters/macos/mci-brain-ffi/`.
- `onboarding/` — setup's five screens, the two permissions, the Ask key,
  and Choose Apps.
- `demo-memory/` — `demo-screens`, which draws Demo Memory's made-up
  screenshots and seals them with the capture helper's codec.
- `mind/` — `hippocampus-mind`, which writes answers, notes and what is
  learned with Apple Intelligence or a model server on the Mac.
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
