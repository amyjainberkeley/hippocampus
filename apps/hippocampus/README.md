# apps/hippocampus/

The Hippocampus menu-bar app — the primary shipping shell users
launch. Supervises `MCICaptureHelper` (Swift) + `mci-agent` (Rust)
as child processes and pipes helper stdout → agent stdin. Ships as
the notarized `.app` inside the DMG installer.

## Contents

- `Package.swift` — Swift-PM manifest. Two products:
  - `Hippocampus` (executable) — the `@main` `App` with
    `MenuBarExtra`.
  - `HippocampusKit` (library) — `ProcessSupervisor`, protocols,
    view models, split so unit tests link without the binary.
- `Sources/` — the two targets above.
- `Resources/` — app icon, entitlements, Info.plist, appcast keys.
- `Tests/` — XCTest suites (supervisor lifecycle, view-model state).
- `Package.resolved` — pinned Swift-PM dependency versions.

## Related

- `../../adapters/macos/MCICaptureHelper/` — the Swift child process
  this app launches.
- `../agent/` — the Rust child process this app launches.
- `../../adapters/macos/mci-brain-ffi/` — the FFI linked for the
  in-app recall panel.
- `../../scripts/build-installer.sh` — packages this app into a DMG.

## When to edit here

Menu-bar UI, child-process supervision (spawn, restart, teardown),
Sparkle appcast wiring, and the entitlements/Info.plist that the
Developer-ID-signed release depends on. If the change is about
capture, brain, or crypto, it belongs in `../../core/` or
`../../adapters/macos/` — not here. Entitlement changes are
CSO-gated.
