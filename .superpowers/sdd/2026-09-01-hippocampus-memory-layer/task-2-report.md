# Task 2 Final Repair Report R4: Fail-Closed Capture And Verified Lifecycle

Status: every repository-local R4 P1/P2/P3 finding is repaired in the focused
commit containing this report on `codex/hippocampus-v1`. Nothing was pushed,
signed, notarized, uploaded, or published.

R4 review base: `3e8248aac5ba8512f47b874d40cda3543ae6b684`.
Concurrent Task 5 commits `dd960ad73c8486c3eaa3590e8e8504d2da6faa85`
and `1f2bc12b87bcff579d87ddbcf1b45e8c1301cbae` landed as parents during
this repair and were preserved.

## R4 Finding Disposition

| Finding | Disposition |
|---|---|
| P1-1 whole-document TOML authority | Closed locally. TOMLKit 0.6.0 parses the complete document before a root boolean is read or changed. Malformed syntax, unrelated malformed root values, wrong types, duplicate semantic keys including escaped quoted keys, and ambiguous table conflicts fail closed. |
| P1-2 first-run and legal guarantees | Closed as product truth. First-run copy describes row deletion plus local compaction. One canonical Markdown license source generates both installer artifacts. Release checks reject drift and unimplemented guarantees before DMG staging. Legal-owner approval remains a release gate and is not fabricated here. |
| P2-1 composed termination proof | Closed locally. An extracted coordinator composes real normal and TERM-resistant child pairs through `ProcessSupervisor.state == .stopped`, restart scheduling, cleanup, and the termination reply. Restart and a positive reply occur only after both tracked PIDs are absent. |
| P2-2 active false claims | Closed. Seeded demo memory, the boot guard, the data-flow diagram, README examples, architecture, onboarding, and installer legal copy now match the shipped Rust cosine scan, CPU-pinned Core ML, file-Keychain boundary, and row-deletion behavior. |
| P3-1 Task 5 compile-drift report | Closed. R4 found typed-outcome compile drift in both `apps/agent/tests/chunker_event_wire.rs` and `apps/agent/tests/wire_e2e_fixture.rs`. Preserved concurrent Task 5 commits `dd960ad` and `1f2bc12` repaired them respectively. A full agent test compile now passes, and neither test is part of the Task 2 commit. |

## Capture Authority

- `RuntimeConfig` uses TOMLKit's toml++-backed TOML 1.0 parser. The package is
  exact-pinned at 0.6.0 and `Package.resolved` pins revision
  `ec6198d37d495efc6acd4dffbd262cdca7ff9b3f`.
- Reads parse the complete UTF-8 document and take only a typed root boolean.
  Any parser error or non-boolean root value returns false.
- Writes first parse the complete existing document and reject malformed,
  duplicate, conflicting, or wrong-typed authority without changing its bytes.
  The existing line editor then preserves comments, indentation, tables, and
  prefix siblings; the emitted document is reparsed and its root value verified
  before atomic replacement.
- Standalone and XCTest behavior cases cover an unterminated table after a valid
  key, an unrelated malformed assignment and array after a valid key, an escaped
  `"\u0063apture_enabled"` duplicate, wrong types, quoted duplicates, table-local
  keys, comment preservation, insertion before tables, and on-to-off relaunch.

## Legal And Product Truth

- `docs/legal/terms-of-service.md` is the single reviewed product-behavior
  source. It describes the current local pipeline, same-user process boundary,
  explicit capture setting, row deletion, database compaction, and limitations.
  Its source header keeps legal-owner approval explicit.
- `generate-eula.py` deterministically generates `EULA.rtf` and `sla.r` and has
  a read-only `--check` mode. It rejects unimplemented hardware, deletion, sync,
  vector-extension, and absolute-decryption guarantees in the canonical source.
- `build-installer.sh` runs that check before `--verify-assets` can succeed and
  before normal release assembly stages the app. Missing or stale artifacts fail
  instead of being silently reused or regenerated during release assembly.
- `scripts/test-task-2-product-truth.sh` verifies active copy, mutates a fixture
  artifact to prove drift fails, mutates the source to prove a prohibited claim
  fails, and is wired into the local check catalog and release-contract CI.
- TOMLKit and bundled toml++ attributions were added to the shipped notice.

## Shutdown Composition

- `ApplicationTerminationCoordinator` owns the awaited shutdown, restart,
  cleanup, and reply sequence. `AppDelegate` still returns AppKit
  `.terminateLater`; a failed stop presents the error and replies false.
- `ProcessSupervisor.shutdownAndWait` remains the state boundary. It publishes
  `.stopped` only after topology stop succeeds, and concurrent callers share one
  shutdown task.
- `SupervisorProcessShutdown` remains the sole TERM-grace-to-SIGKILL production
  boundary and rejects surviving Foundation processes or PIDs.
- `DelayedApplicationRestartLauncher` is extracted from AppDelegate and creates
  its child through the centralized reusable-key scrubber.
- The standalone composed fixture launches actual `/bin/sh` helper and agent
  processes for normal quit and TERM-resistant restart. It invokes the real
  `ProcessSupervisor` and coordinator, then proves `.stopped`, PID death,
  restart ordering, cleanup, and the positive reply. XCTest also covers success
  ordering and failed-stop false-reply/no-restart/no-cleanup behavior.
- `applicationWillTerminate` remains idempotent cleanup only; it does not start
  an unawaited second shutdown.

## Verification

- `cargo test -p mci-agent --test key_resolver --test register_mcp --test keychain_packaging_contract --test child_command_environment --locked`: PASS, 45 passed and 0 failed (21 resolver, 13 MCP registration, 9 packaging, 2 child environment).
- `cargo check -p mci-agent --bins --locked`: PASS.
- `scripts/swift-package.sh build --package-path apps/hippocampus`: PASS with pre-existing warnings.
- `scripts/swift-package.sh build --package-path apps/onboarding`: PASS.
- Standalone Swift behavior executables: PASS, 8/8. This includes whole-document TOML, composed real-process lifecycle, asynchronous Key Wrap audit, detached KeyStore access, transition generations, child environment receipt, custody cancellation, and normal/resistant shutdown primitives.
- `scripts/test-agent-key-custody-runner.sh`: PASS, 3 assertions and 0 failures.
- `scripts/test-supervisor-stop-policy.sh`: PASS, 1 assertion and 0 failures.
- `scripts/test-release-contract.sh`: PASS, 86 assertions and 0 failures.
- `scripts/test-task-2-product-truth.sh`: PASS, including drift and prohibited-guarantee mutation cases.
- `python3 assets/installer/generate-eula.py --check`: PASS.
- `scripts/build-installer.sh --verify-assets`: PASS for canonical brand and legal artifacts.
- `xcrun swiftc -parse` over changed Swift production, fixture, and XCTest sources: PASS.
- `rustfmt --edition 2021 --check apps/agent/src/bin/mci_seed_brain.rs`: PASS.
- `python3 -m py_compile assets/installer/generate-eula.py`: PASS.
- `bash -n` over changed shell scripts and `git diff --check`: PASS.
- `scripts/swift-package.sh test --package-path apps/hippocampus`: BLOCKED by the active Command Line Tools installation, which cannot import `XCTest`. Full XCTest is not claimed.
- `cargo test -p mci-agent --locked --no-run`: PASS. R4 had found compile
  drift in both `apps/agent/tests/chunker_event_wire.rs` and
  `apps/agent/tests/wire_e2e_fixture.rs`; preserved Task 5 parents `dd960ad`
  and `1f2bc12` repair them respectively. Neither repair is staged by Task 2.

## Changed Files

- `.github/workflows/release-contract.yml`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/progress.md`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-2-report.md`
- `ARCHITECTURE.md`
- `CHANGELOG.md`
- `NOTICE`
- `README.md`
- `apps/agent/src/bin/mci_seed_brain.rs`
- `apps/hippocampus/Package.resolved`
- `apps/hippocampus/Package.swift`
- `apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift`
- `apps/hippocampus/Sources/HippocampusKit/ApplicationTerminationCoordinator.swift`
- `apps/hippocampus/Sources/HippocampusKit/MciBootGuards.swift`
- `apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift`
- `apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift`
- `apps/hippocampus/Sources/HippocampusKit/SupervisorProcessRuntime.swift`
- `apps/hippocampus/Sources/HippocampusKit/SupervisorProcessShutdown.swift`
- `apps/hippocampus/Tests/Fixtures/RuntimeConfigBehavior.swift`
- `apps/hippocampus/Tests/Fixtures/SupervisorLifecycleBehavior.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/MenuBarLifecycleTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/ProcessSupervisorTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/RuntimeConfigTests.swift`
- `apps/onboarding/Sources/Onboarding/Slides/RetentionSlide.swift`
- `assets/installer/EULA.rtf`
- `assets/installer/generate-eula.py`
- `assets/installer/sla.r`
- `docs/assets/data-flow-diagram.svg`
- `docs/legal/terms-of-service.md`
- `scripts/build-installer.sh`
- `scripts/check.sh`
- `scripts/test-release-contract.sh`
- `scripts/test-task-2-product-truth.sh`

## Residual Owner And API Gates

- Complete legal-owner review of the canonical terms before public distribution;
  this repair verifies product truth and artifact identity, not legal advice.
- Implement a safe access-object inspection/migration API before claiming the
  Keychain ACL has been observed. Do not infer it from value readability or
  rewrite secret bytes merely to inspect it.
- Build two Developer-ID-signed versions and prove Hippocampus,
  `MCICaptureHelper`, `mci-agent`, and Recall retain Keychain access across an
  upgrade without an unexpected prompt.
- Exercise locked, denied, canceled-interaction, duplicate-add, and interrupted
  migration outcomes in a disposable macOS account.
- Run full XCTest with full Xcode.
- Run physical-Mac TCC denial/recovery, capture-off/on, rollback overlap, normal
  Quit, Quit-and-Restart, TERM-resistant shutdown, and sustained capture on the
  release candidate.
- Preserve Task 5's typed-outcome repairs in parents `dd960ad` and `1f2bc12`;
  both tests named by R4 now compile in the full agent package.
- Signing, notarization, upload, publication, and production Keychain/TCC access
  were intentionally not performed.

Concurrent Task 5 commits `dd960ad` and `1f2bc12` were preserved as this
repair's parents. Their files are not in this report's changed-file ledger or
Task 2 commit. `scripts/__pycache__/` was also preserved and not staged.
