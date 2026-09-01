# Task 2 Final Repair Report R3: Key Custody And Capture Lifecycle

Status: repository-local R3 P1/P2 findings repaired in the focused commit containing this report on `codex/hippocampus-v1`. Nothing was pushed, signed, notarized, uploaded, or published.

Starting HEAD: `e66babebb5dc81c2e54797c6fa5f57a7e569e6a4`

## R3 Finding Disposition

| Finding | Disposition |
|---|---|
| P1-1 awaited Quit / Quit-and-Restart | Closed locally. AppKit returns `terminateLater`; it replies true only after the shared supervisor shutdown proves helper and agent death. Restart scheduling happens after that proof. A failed shutdown replies false and leaves the GUI visible. |
| P1-2 MainActor Keychain audit | Closed locally. Audit reads use the detached `KeyStoreAccess` boundary. The MainActor view model exposes loading, loaded, and error states. |
| P1-3 invalid TOML capture authority | Closed locally. Only exact TOML `true` or `false` at the root key is accepted. Invalid types, malformed assignments, semantic quoted/bare duplicates, and table-local keys fail closed. |
| P2-1 fabricated ACL health | Closed as a product-truth defect. The UI reports key readability and ACL status separately; successful data access always leaves access-control verification `unverified`. Real access-object inspection and signed continuity remain owner/API gates. |
| P2-2 Rust child environment inheritance | Closed locally. Every source-level agent-owned `std::process::Command` construction routes through one scrubber that removes all four reusable-key or removed-authority variables. |
| P2-3 fake-only shutdown tests | Closed locally. A standalone fixture launches real normal and TERM-resistant `Process` pairs, calls the production shutdown boundary, and proves both PIDs are absent before completion. |
| P2-4 packaging contract drift | Closed. The focused contract now checks the current release-signing semantics without restoring stale documentation. |
| P2-5 false custody/retrieval/deletion copy | Closed in README and architecture truth. Copy now states file-Keychain readability, CPU-pinned Core ML, Rust-side cosine scan, deferred sqlite-vec, and row deletion plus `VACUUM`. |

## Shutdown Design

- `SupervisorProcessShutdown` is the only production TERM-to-KILL boundary. It resumes paused children, sends TERM, waits for the configured grace period, sends KILL to survivors, then verifies both Foundation process state and PID absence.
- `FoundationSupervisorTopology.stop` delegates to that boundary and cleans up only after verified death.
- A partial helper launch is also closed through the same boundary if the agent fails to launch; the helper handle is not discarded while it may still be alive.
- `ProcessSupervisor.shutdownAndWait` is idempotent for concurrent callers. It cancels retries and invalidates transition acceptance before stopping, but does not publish `.stopped` until topology shutdown succeeds. Failure publishes a visible crash state.
- `AppDelegate.applicationShouldTerminate` uses AppKit terminate-later/reply. Quit-and-Restart launches its delayed reopen child only after verified shutdown. `applicationWillTerminate` performs idempotent resource cleanup and does not start an unawaited second stop.

## Audit And Custody Truth

- `KeyWrapAuditor.inspectKeychain` is async and performs the final typed Keychain read outside MainActor.
- `KeyWrapAuditViewModel` keeps UI mutation on MainActor and represents loading, loaded, and failed states explicitly.
- The report names whether the key was readable. It never maps readability to sealing or ACL health.
- The access-control field states that the access object was not inspected. The report also names access-object inspection and signed cross-version continuity as release-owner gates.
- No key bytes are rendered, logged, placed in child argv, or added to reports.

## Capture Authority

- Root `capture_enabled` accepts only the TOML boolean tokens `true` and `false` with optional whitespace/comment text.
- Numeric values, strings, arrays, inline tables, malformed tokens, malformed exact assignments, and semantically duplicate bare/basic-quoted/literal-quoted keys fail closed.
- A `capture_enabled` key inside a TOML table is not root capture authority.
- Writes preserve unrelated lines, comments, leading indentation, and similarly prefixed siblings. They collapse root semantic duplicates to one canonical bare key.
- If tables already exist and no root key exists, the writer inserts the root key before the first table header. Fresh-instance relaunch tests prove malformed numeric authority remains off and on-to-off remains off.

## Child Environment Policy

- `apps/agent/src/child_command_environment.rs` owns the Rust denylist and `sanitized_command` constructor.
- The brief worker `date +%z` process and every other `Command` spawn under `apps/agent/src` use that constructor.
- The denylist removes `MCI_DB_KEY_HEX`, `MCI_DB_KEY_FILE`, `MCI_DEVELOPMENT_FILE_KEY`, and `HIPPOCAMPUS_ENABLE_V2P1`.
- A process-level test runs `/usr/bin/env`, verifies an ordinary marker survives, and verifies all four forbidden values are absent from the received environment.

## Verification

- `cargo test -p mci-agent --test key_resolver --test register_mcp --test keychain_packaging_contract --test child_command_environment --locked`: PASS, 45 passed and 0 failed (21 resolver, 13 MCP registration, 9 packaging, 2 child environment).
- `cargo check -p mci-agent --bins --locked`: PASS.
- `scripts/swift-package.sh build --package-path apps/hippocampus`: PASS with pre-existing warnings.
- Standalone Swift behavior executables: PASS, 7/7 for strict runtime TOML, async audit responsiveness/error state, real normal/resistant process shutdown, detached KeyStore access, transition generations, process-level child environment, and custody cancellation boundaries.
- `scripts/test-agent-key-custody-runner.sh`: PASS, 3 printed assertions and 0 failures.
- `scripts/test-supervisor-stop-policy.sh`: PASS, 1 printed assertion and 0 failures. This is supplemental; the real-process shutdown fixture is the lifecycle evidence.
- `xcrun swiftc -parse` over every changed Swift source, fixture, and XCTest source: PASS.
- `rustfmt --edition 2021` over every changed Rust source and test: PASS.
- `scripts/swift-package.sh test --package-path apps/hippocampus`: reached test compilation but did not execute XCTest because this Command Line Tools installation has no `XCTest` module. Full XCTest remains an external Xcode gate and is not claimed.
- `cargo test -p mci-agent --locked`: broader package compile remains blocked outside Task 2 by `apps/agent/tests/chunker_event_wire.rs`, which calls `is_empty` and `iter` on the Task 5 `McpRecallOutcome` enum. Task 5 typed-outcome code and this out-of-scope test were not modified.

## Changed Files

- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/progress.md`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-2-report.md`
- `README.md`
- `ARCHITECTURE.md`
- `CHANGELOG.md`
- `apps/agent/src/child_command_environment.rs`
- `apps/agent/src/brief_worker.rs`
- `apps/agent/src/bin/mci_bench.rs`
- `apps/agent/src/bin/mci_calibrate_evidence.rs`
- `apps/agent/src/lib.rs`
- `apps/agent/tests/child_command_environment.rs`
- `apps/agent/tests/keychain_packaging_contract.rs`
- `apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift`
- `apps/hippocampus/Sources/Hippocampus/KeyWrapAuditView.swift`
- `apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift`
- `apps/hippocampus/Sources/HippocampusKit/KeyWrapAudit.swift`
- `apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift`
- `apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift`
- `apps/hippocampus/Sources/HippocampusKit/SupervisorProcessRuntime.swift`
- `apps/hippocampus/Sources/HippocampusKit/SupervisorProcessShutdown.swift`
- `apps/hippocampus/Tests/Fixtures/KeyWrapAuditResponsiveness.swift`
- `apps/hippocampus/Tests/Fixtures/RuntimeConfigBehavior.swift`
- `apps/hippocampus/Tests/Fixtures/SupervisorProcessShutdownBehavior.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/KeyWrapAuditTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/MenuBarLifecycleTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/ProcessSupervisorTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/RuntimeConfigTests.swift`

## Residual Owner And API Gates

- Implement a safe access-object inspection/migration API before claiming the Keychain ACL has been observed. Do not infer it from value readability and do not rewrite secret bytes merely to inspect it.
- Build two Developer-ID-signed versions and prove Hippocampus, `MCICaptureHelper`, `mci-agent`, and Recall retain access across upgrade without an unexpected prompt.
- Exercise locked, denied, canceled-interaction, duplicate-add, and interrupted-migration Security.framework outcomes in a disposable macOS account.
- Run full XCTest with full Xcode.
- Run physical-Mac TCC denial/recovery, generation readiness, rollback overlap, Quit, Quit-and-Restart, resistant-child shutdown, and sustained capture on the release candidate.
- Resolve the separately owned Task 5 `chunker_event_wire` typed-outcome drift before using a full `mci-agent` package run as release evidence.
- Signing, notarization, publication, and production Keychain/TCC access were intentionally not performed.

The Task 5 typed retrieval outcome and the `95ee449` release-model changes were preserved. No core/brain, MCP retrieval/server, release workflow, release script, `Info.plist`, `docs/STATUS.md`, or Task 4/5/6 implementation file was changed by this repair.
