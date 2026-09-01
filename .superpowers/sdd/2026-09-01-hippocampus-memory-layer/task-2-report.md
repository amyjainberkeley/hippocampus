# Task 2 Final Repair Report: Key Custody And Capture Readiness

Status: R2 repair completed in the focused commit containing this report on `codex/hippocampus-v1`; not pushed, signed, notarized, uploaded, or published.

Original repair commit: `a821f65dc2f195309ba0442ffd9a13faec536cd0`

## R2 Repair Summary

- The initializer now models legacy-file presence independently from database presence. With no database, a valid legacy key is reused add-only instead of generating a contradictory key; an existing matching Keychain item finalizes plaintext cleanup. Both states are exercised across two launches with a real SQLCipher brain.
- Runtime TOML reads fail closed on duplicate exact keys. Writes structurally match only the exact assignment, preserve comments and similarly prefixed siblings, and deterministically collapse duplicates. An on-to-off fresh-instance relaunch remains off.
- Supervisor exits and retries are accepted only for the committed generation. Startup, capture changes, rollback, retry, and stop use transition identities; callbacks are suppressed while a transaction owns the topology.
- The final typed Keychain read runs through a detached access boundary. A delayed-key-store fixture proves a MainActor heartbeat remains responsive.
- Every production `Process` in Hippocampus and onboarding is created through a package-local shared factory that strips reusable key variables and the removed capture authority. Process-level fixtures inspect the actual environment received by `/usr/bin/env`.
- Custody-runner cancellation installs control before launch, gives SIGTERM a 250 ms grace period, escalates a still-live matching PID to SIGKILL, waits for death, and lets cancellation win launch-failure races. The fixture covers a resistant child, cancel-before-install, cancel-after-exit, and no surviving PID.
- Operator documentation now describes the persisted capture toggle, generation-bound readiness, completed migration behavior, and exact remaining owner gates.

## R2 Verification

- `cargo test -p mci-agent --test key_resolver --locked`: PASS, 21 passed and 0 failed, including two real SQLCipher two-launch no-database legacy tests.
- Standalone Swift behavior fixtures: PASS for runtime TOML, supervisor transition identity, off-MainActor Keychain access, Hippocampus child environment, onboarding child environment, and custody cancellation (`6/6` fixture lanes).
- `scripts/test-agent-key-custody-runner.sh`: PASS, 3 assertions and 0 failures.
- `scripts/swift-package.sh build --package-path apps/hippocampus`: PASS with pre-existing warnings.
- `scripts/swift-package.sh build --package-path apps/onboarding`: PASS.
- Focused changed Swift test-source parsing: PASS. XCTest execution still requires a full Xcode toolchain because this host's Command Line Tools cannot import `XCTest`.
- `cargo test -p mci-agent --test keychain_packaging_contract --locked`: 8 passed and 1 failed because the committed release work removed an exact sentence from out-of-scope `scripts/README.md` while the Task 2 contract still asserts it. Task 2 did not edit the release documentation or test.
- `cargo test -p mci-agent --locked`: blocked during compilation by concurrent Task 5 wire tests that call vector methods on the new `McpRecallOutcome` enum. The four errors are outside Task 2 ownership; the focused key resolver and MCP registration lanes pass.

## R2 Residual Owner And API Gates

- P2-1 remains explicit: current adapters can read data and create an ACL-protected item but cannot safely inspect or migrate an existing item's access object without changing secret bytes. Do not represent the four-consumer ACL as observed until that API exists and a real signed upgrade test records it.
- On a disposable physical Mac, use two Developer-ID-signed versions to prove Hippocampus, `MCICaptureHelper`, `mci-agent`, and Recall can read the same item across upgrade without an unexpected prompt.
- Exercise real locked, denied, canceled-interaction, duplicate-add, and interrupted-migration Security.framework outcomes in a disposable account.
- Run full Swift XCTest with Xcode, then live TCC denial/recovery, generation-bound readiness, rollback overlap, and sustained capture on release hardware.

## Final Design

- Production custody uses Apple's macOS file-based Keychain model: one non-synchronizable generic-password item with service `ai.hippocampus.brain`, account `database-key-v1`, storage model `file-keychain-acl-v1`, `kSecUseDataProtectionKeychain=false`, and a `SecAccess` ACL containing `SecTrustedApplication` entries for `Hippocampus`, `MCICaptureHelper`, `mci-agent`, and `recall-ui`.
- This is intentionally not the data-protection Keychain. There is no `keychain-access-groups` entitlement or provisioning-profile sharing flow. Stable Developer ID signing is a release prerequisite because file-Keychain ACL trust depends on stable executable designated requirements. Ad-hoc signing is available only through the explicit debug development option and is not represented as update-safe.
- The Rust `mci-keychain` crate remains the sole unsafe Security.framework adapter. The repair adds no second Keychain FFI implementation. Swift consumers use native Security.framework clients with the same query-domain attributes.
- Production children receive only the content-free service/account/storage-model reference. Raw and file keys are stripped from helper, agent, Recall, onboarding, and Claude-registration child environments. Raw/file behavior remains only behind exact `MCI_DEVELOPMENT_FILE_KEY=1` development mode, including seed and demo tools.

## Migration Semantics

- A valid existing Keychain item is never overwritten. Missing, denied, locked/interaction-unavailable, malformed, and generic read failures remain distinct.
- If `mci.sqlite` exists and the item is missing, initialization never generates. It requires an exact 64-character ASCII-hex legacy `dev.key`, opens the existing SQLCipher database read-only, queries its schema/stats, adds that exact key with the packaged ACL, re-reads Keychain, and proves the re-read value opens the same database.
- The plaintext legacy file is preserved on malformed/wrong key, denied/locked access, add failure, post-add read failure, post-add database validation failure, mismatch, or deletion failure. No key bytes are logged.
- After full validation, the legacy file is removed. A same-key duplicate race is accepted only after winner re-read and database validation, then removes the legacy file.
- Restart after interrupted add is handled explicitly: if Keychain and the database validate while `dev.key` remains, the legacy key is independently validated, required to equal the Keychain key, and then removed. Malformed, wrong, or ambiguous legacy material fails visibly and remains untouched.
- Generation occurs only when no database exists. Entropy failure and ACL-contract failure close initialization.

## Capture And Product Behavior

- `HIPPOCAMPUS_ENABLE_V2P1` is no longer a capture authority. Only the persisted preference translated into explicit supervisor `--capture` argv can construct content-bearing capture/context/OCR resources.
- The helper resolves Keychain before capture, exits nonzero on custody or stream-start failure, and writes a generation-bound readiness receipt only after `SCStream.startCapture()` succeeds. Capture-off readiness does not construct capture resources.
- The supervisor waits for readiness from the expected process generation and for both processes to remain alive. It persists and publishes a capture preference only after verified readiness. Stop, startup, persistence, timeout, early-exit, partial-stop, and rollback failures leave a visible actual/closed state; rollback creates and verifies a fresh prior topology.
- Product app, `mci-brain`, helper, Recall, onboarding, Key Wrap Audit, docs, and CLI help use the shared Keychain-reference contract. Production defaults no longer select `FileKeyStore`.
- Removing the raw-key brain-stats subprocess leaves no stored-event-count source. Health status therefore reports `N frames processed`; delivered frames are never relabeled as stored events.
- Recall links only a deterministic profile-specific staged `libmci_brain_ffi.a`. The wrapper builds and stages the requested Cargo profile before SwiftPM, and release has no `target/debug` fallback.

## Changed Files

- `README.md`
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift`
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/CaptureLaunchOptions.swift`
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/HelperReadinessReceipt.swift`
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/MciV2P1Gate.swift` (deleted)
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/KeyframeBlobWriter.swift`
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/OCRPostAllowEmitter.swift`
- `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/CaptureLaunchOptionsTests.swift`
- `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/HelperReadinessReceiptTests.swift`
- `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/MainSwiftWiringTests.swift`
- `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/MciV2P1GateTests.swift` (deleted)
- `apps/agent/src/bin/mci_agent.rs`
- `apps/agent/src/bin/mci_brain.rs`
- `apps/agent/src/bin/mci_seed_brain.rs`
- `apps/agent/src/bin/mci_seed_brief.rs`
- `apps/agent/src/doctor.rs`
- `apps/agent/src/key_resolver.rs`
- `apps/agent/src/lib.rs`
- `apps/agent/src/supervisor.rs`
- `apps/agent/src/v2p1_gate.rs` (deleted)
- `apps/agent/tests/key_resolver.rs`
- `apps/agent/tests/keychain_packaging_contract.rs`
- `apps/hippocampus/Resources/build-app.sh`
- `apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift`
- `apps/hippocampus/Sources/Hippocampus/KeyWrapAuditView.swift`
- `apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift`
- `apps/hippocampus/Sources/HippocampusKit/KeyWrapAudit.swift`
- `apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift`
- `apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift`
- `apps/hippocampus/Sources/HippocampusKit/SupervisorProcessRuntime.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/KeyWrapAuditTests.swift`
- `apps/hippocampus/Tests/HippocampusKitTests/ProcessSupervisorTests.swift`
- `apps/onboarding/Sources/Onboarding/KeyWrapAuditView.swift`
- `apps/onboarding/Sources/Onboarding/LocalKeyGenerator.swift`
- `apps/onboarding/Sources/Onboarding/Slides/TrustSlide.swift`
- `apps/onboarding/Sources/OnboardingKit/KeyWrapAudit.swift`
- `apps/onboarding/Tests/OnboardingKitTests/KeyWrapAuditTests.swift`
- `apps/recall-ui/Package.swift`
- `docs/DESIGN.md`
- `docs/STATUS.md`
- `scripts/README.md`
- `scripts/build-installer.sh`
- `scripts/demo.sh`
- `scripts/render-cli-screenshot.py`
- `scripts/stage-recall-ffi.sh`
- `scripts/swift-package.sh`
- `scripts/try-it.sh`
- `scripts/verify-keychain-acl-upgrade.sh`

## Exact Verification

- `cargo test -p mci-agent --test key_resolver --locked`: PASS, 19 passed. Covers clean install, valid migration/removal, malformed/wrong legacy preservation, denied/locked preservation, duplicate race, post-add read/validation failure, deletion failure, and restart-after-add cleanup/mismatch.
- `cargo test -p mci-agent --test keychain_packaging_contract --locked`: red first at 7 passed/2 failed, then PASS at 9 passed after the installer and explicit development-gate fixes.
- `cargo test -p mci-agent --test register_mcp --locked`: PASS, 13 passed; MCP registration stores references only and development raw/file fallback requires the explicit gate.
- `cargo check -p mci-agent --bins --locked`: PASS for all agent binaries and the shared Keychain adapter.
- `cargo test -p mci-agent --lib --locked`: PASS, 333 passed and 1 model-dependent test ignored.
- `cargo test -p mci-agent --locked`: PASS across all unit, binary, integration, and doc-test targets; no failures. The package library reported 333 passed and 1 ignored, with the focused 19/9/13 suites also green in the full run.
- `SWIFT_EXEC_MANIFEST=/tmp/hippo-swiftc-manifest-wrapper-20260901 scripts/swift-package.sh build --package-path adapters/macos/MCICaptureHelper`: PASS.
- `SWIFT_EXEC_MANIFEST=/tmp/hippo-swiftc-manifest-wrapper-20260901 scripts/swift-package.sh build --package-path apps/hippocampus`: PASS; only pre-existing Swift warnings.
- `SWIFT_EXEC_MANIFEST=/tmp/hippo-swiftc-manifest-wrapper-20260901 scripts/swift-package.sh build --package-path apps/onboarding`: PASS.
- `SWIFT_EXEC_MANIFEST=/tmp/hippo-swiftc-manifest-wrapper-20260901 scripts/swift-package.sh build -c release --package-path apps/recall-ui`: PASS. The initial release link selected only `.build/mci-brain-ffi/release/libmci_brain_ffi.a`; a final cached release build also passed.
- `cmp target/release/libmci_brain_ffi.a apps/recall-ui/.build/mci-brain-ffi/release/libmci_brain_ffi.a`: PASS, byte-identical staged release archive.
- Wrapper-prefixed `swift-package.sh test` was attempted for MCICaptureHelper, Hippocampus, Recall, and onboarding. MCICaptureHelper, Hippocampus, and onboarding reached test compilation but this CLT has no `XCTest` module. Recall debug test compilation is blocked earlier by the existing missing `PreviewsMacros` plugin. No XCTest case executed on this host.
- `xcrun swiftc -parse` over all changed helper, Hippocampus, Recall, and onboarding test sources: PASS in two explicit source sets.
- `scripts/test-swift-package.sh`: PASS, 25 passed and 0 failed.
- `scripts/test-release-contract.sh`: PASS, 36 passed and 0 failed. This also exercised coordinator-owned release-contract changes present in the shared worktree; none were included in the Task 2 commit.
- `bash -n` over `build-app.sh`, `build-installer.sh`, `swift-package.sh`, `test-release-contract.sh`, `stage-recall-ffi.sh`, `verify-keychain-acl-upgrade.sh`, `demo.sh`, and `try-it.sh`: PASS.
- `rustfmt --edition 2021` over the changed Task 2 Rust source and test files: PASS.
- Custody/capture source sweeps for the removed environment authority, debug Recall archive fallbacks, stale file-store defaults, dead `devKeyPath`, and false `events captured` health copy: PASS. Remaining raw-key references are sanitizer deny entries, migration handling, or explicitly gated development tools.
- `git diff --cached --check`: PASS before commit.

## Remaining Owner Actions And Risks

- Run the committed Swift XCTest cases on a full Xcode toolchain that supplies `XCTest` and `PreviewsMacros`. Product compilation and test-source parsing passed here, but they are not substitutes for XCTest execution.
- Build two real Developer-ID-signed app versions and run `scripts/verify-keychain-acl-upgrade.sh OLD.app NEW.app`, followed by a disposable release-test-Mac Keychain create/read upgrade smoke for all four ACL consumers. The repository test is content-free and intentionally did not mutate or probe Amy's production Keychain.
- Run clean-install, valid legacy migration, interrupted-after-add restart, and deletion-failure acceptance on a backed-up disposable macOS account before shipping. Unit tests exercise every state-machine branch without touching production custody.
- Run live Screen Recording denial, successful readiness, timeout, capture toggle, rollback, and sustained capture tests under real TCC/SCStream conditions.
- The Recall release link emitted existing deployment-version warnings when Rust objects built for macOS 26.5 linked into the macOS 14 Swift target. Profile selection is now deterministic, but release engineering should align deployment targets.
- `SecAccess` and `SecTrustedApplication` are deprecated but are the TN3137-compatible sharing mechanism for the selected file-based Keychain model. Migrating to data-protection access groups would require a separately provisioned entitlement/signing architecture for every binary.
- Explicit ad-hoc debug artifacts are disposable and cannot prove cross-version ACL continuity. They must not be promoted or used as release upgrades.
- Outer-DMG Developer ID signing remains coordinator-owned and was intentionally left for the follow-up announced after this Task 2 freeze. Task 2 made no changes after that coordination point.
- Signing, notarization, publication, and production Keychain/TCC access were not performed.
- Concurrent coordinator changes to `Info.plist`, `.github`, and independent release scripts remained unstaged and were not included in `a821f65`.
