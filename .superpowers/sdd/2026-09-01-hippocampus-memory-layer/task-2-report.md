# Task 2 Final Repair Report R6: Lifecycle, Retention, And Capture Truth

Status: all three repository-local R6 findings are repaired on
`codex/hippocampus-v1`. This repair was developed against the shared branch
after Task 4/5 advanced HEAD to `756b339`. It does not modify Task 4/5 core,
Recall, capture-helper, benchmark, or FFI files. Nothing was pushed, signed,
notarized, uploaded, or published.

## Finding Disposition

| Finding | Disposition |
|---|---|
| P1 shutdown races startup and capture reconfiguration | Repaired. Shutdown invalidates the active transition before awaiting topology stop. Startup, retry, and capture reconfiguration recheck cancellation plus transition ownership after every suspension. A launched but uncommitted topology is stopped, and invalidated work cannot publish `.running` or schedule rollback/retry. The production lifecycle fixture covers shutdown during key preparation, startup readiness, and capture-reconfiguration readiness in addition to normal quit and resistant-child restart. |
| P1 retention picker and purge worker use different authorities | Repaired. `~/Library/Application Support/MCI/retention.json` is now the sole active authority. Preferences atomically writes the worker vocabulary (`forever`, `thirtyDays`, `sevenDays`, `custom`), publishes state only after a successful commit, validates custom days, preserves malformed canonical state fail-closed, and migrates legacy `days30`/`days90` UserDefaults once. A Swift-to-Rust process contract proves the production worker consumes every picker output and an existing file replacement. |
| P2 capture-off topology presents Recording/Stop Recording | Repaired. Menu icon, header, health copy, pause action, and recording command derive from both topology state and `captureEnabled`. A healthy agent-only topology now displays Idle and Start Recording; Start/Stop changes capture policy without incorrectly stopping the memory agent. Standalone and XCTest fixtures pin default-off behavior. |

## Truth And CI Gates

- `test-task-2-product-truth.sh` asserts the canonical Swift and Rust path,
  atomic replacement and `0600` mode, worker mode vocabulary, absence of a
  competing UserDefaults write, and capture-aware production call sites.
- `test-release-contract.sh` requires the picker-to-worker contract in local
  checks and release CI. Push and pull-request filters watch all R6 production
  sources, standalone fixtures, XCTest cases, and contract scripts.
- `scripts/check.sh` exposes `retention-policy-contract` as a blocking test lane.
- The retention fixture rejects malformed canonical JSON without overwriting it,
  proves a failed disk write leaves the published policy unchanged, and checks
  that atomic replacement leaves no temporary siblings.

## TDD And Verification

- Red lifecycle fixture: shutdown during suspended key preparation resumed into
  a non-stopped state before transition invalidation was implemented.
- Red retention contract: Swift lacked worker-compatible policy cases, disk
  persistence, custom days, and capture-aware status/control derivation.
- `scripts/swift-package.sh run --package-path apps/hippocampus
  SupervisorLifecycleBehavior`: PASS, 5 composed behaviors including real
  normal/resistant child PIDs and all three suspension races.
- `scripts/test-retention-policy-contract.sh`: PASS. Swift exercised four
  picker modes, replacement, malformed-file, failed-write, and capture-off
  behaviors; Rust process contract: 1 passed, 0 failed.
- `cargo test -p mci-agent retention_worker::tests --lib --locked`: PASS,
  9 passed, 0 failed.
- `scripts/test-task-2-product-truth.sh`: PASS.
- `scripts/test-release-contract.sh`: PASS, 117 passed, 0 failed.
- `scripts/swift-package.sh build --package-path apps/hippocampus`: PASS,
  including the Hippocampus executable and standalone fixtures.
- Focused `swift test` was attempted, but this Command Line Tools host has no
  `XCTest` module. Full XCTest remains an external full-Xcode gate and is not
  claimed.
- Focused Rust formatting, changed-shell syntax, workflow lint, and
  `git diff --check`: PASS.

## Changed Files

- `.github/workflows/release-contract.yml`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-2-report.md`
- `apps/agent/src/retention_worker.rs`
- `apps/agent/tests/retention_preferences_contract.rs`
- `apps/hippocampus/Package.swift`
- `apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift`
- `apps/hippocampus/Sources/Hippocampus/PreferencesWindow.swift`
- `apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift`
- `apps/hippocampus/Sources/HippocampusKit/MenuBarStatus.swift`
- `apps/hippocampus/Sources/HippocampusKit/PreferencesStore.swift`
- `apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift`
- `apps/hippocampus/Sources/HippocampusKit/SupervisorTransitionGate.swift`
- `apps/hippocampus/Tests/Fixtures/RetentionPreferencesBehavior.swift`
- `apps/hippocampus/Tests/Fixtures/SupervisorLifecycleBehavior.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/MenuBarQuickActionsTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/PreferencesStoreTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/ProcessSupervisorTests.swift`
- `scripts/check.sh`
- `scripts/test-release-contract.sh`
- `scripts/test-retention-policy-contract.sh`
- `scripts/test-task-2-product-truth.sh`

## Residual Owner And External Gates

- Run full XCTest with full Xcode.
- Complete the existing Developer-ID continuity, Keychain access-object,
  physical-Mac TCC/lifecycle, sustained-capture, signing, notarization, legal
  approval, and publication gates before release.
- The repository gates verify behavior and artifact consistency; they do not
  constitute legal approval.

Concurrent Task 4/5 work was preserved. `scripts/__pycache__/` remains untouched
and untracked.
