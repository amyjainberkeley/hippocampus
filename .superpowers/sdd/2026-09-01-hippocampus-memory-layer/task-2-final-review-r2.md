# Task 2 Final Security And Reliability Review R2

Reviewed `a821f65dc2f195309ba0442ffd9a13faec536cd0` plus follow-up
`96496ed` against `task-2-brief.md`, `task-2-review.md`, and
`task-2-final-review.md`. Production and test sources were not edited.

## Findings

### P0

No P0 finding.

### P1

#### P1-1: A legacy key without a database is stranded, then bricks the next launch

`apps/agent/src/key_resolver.rs:415-424` records only whether the database exists.
When the Keychain item is missing and the database does not exist,
`apps/agent/src/key_resolver.rs:451-468` generates a new key without inspecting an
existing `dev.key`; removal is limited to the database-exists branch at
`apps/agent/src/key_resolver.rs:486-493`. The existing-Keychain path likewise
ignores `dev.key` while no database exists at `apps/agent/src/key_resolver.rs:426-449`.

That state is reachable after an interrupted old install or a removed database.
The first launch leaves plaintext behind and creates a new Keychain key. After the
agent creates a database with that new key, the next launch treats the old
plaintext as an interrupted migration, tries it against the new database at
`apps/agent/src/key_resolver.rs:428-437`, and fails closed forever. The test named
`clean_install_generates_only_when_no_database_exists_and_rereads_keychain` starts
with no legacy file at `apps/agent/tests/key_resolver.rs:263-292`; no test covers
either no-database/existing-legacy state across two launches.

Required repair: define and test both no-database legacy states. Reuse the exact
syntactically valid legacy value (add-only, re-read, compare, then remove) before
allowing a new database to be created, or surface a closed recovery state. Never
leave an unrelated Keychain key and plaintext key to become contradictory on the
next launch.

#### P1-2: A valid TOML layout can make capture silently re-enable after restart

The reader trims whitespace and accepts the first exact key at
`apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift:80-92`, but the writer
uses an untrimmed prefix match at
`apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift:53-60`. For valid TOML
such as ` capture_enabled = true`, writing `false` appends a second key. The reader
continues returning the first `true`, so the current process can look off while the
next launch captures again. The prefix match can also overwrite a distinct key
such as `capture_enabled_backup`.

`apps/hippocampus/Tests/HippocampusKitTests/RuntimeConfigTests.swift:116-118`
explicitly selects the first duplicate but has no formatted-input update test.

Required repair: update an exact parsed key, reject or deterministically collapse
duplicates, and test leading whitespace, comments, similarly prefixed keys, and an
on-to-off relaunch round trip.

#### P1-3: Unexpected-exit retries race transactional rollback

Every generation installs an unexpected-exit callback at
`apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift:243-248`. During a
requested enable, an early helper/agent exit changes state and schedules an
independent delayed restart at
`apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift:274-293`, while the
failing `startTopology` and `applyCaptureEnabled` concurrently stop and restart the
prior topology at `apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift:189-205`
and `:261-265`. The pending retry is neither cancelled nor bound to the committed
transition generation. It can stop a rollback generation while readiness is being
awaited, producing a false crash, `partialStop`, or a topology/state mismatch.

The fake topology discards the callback at
`apps/hippocampus/Tests/HippocampusKitTests/ProcessSupervisorTests.swift:82-90`, so
the rollback tests at `:258-316` cannot exercise this race.

Required repair: give each reconfiguration a transition token, suppress/cancel
automatic retries while it owns startup/rollback, and accept exit/retry work only
for the active committed generation. Add a deterministic test that fires the real
callback during requested startup and during rollback readiness.

#### P1-4: `96496ed` removes one MainActor wait, but startup still performs a synchronous Keychain read there

The follow-up correctly moves `Process.waitUntilExit()` into the detached runner at
`apps/hippocampus/Sources/HippocampusKit/KeyCustodyCommandRunner.swift:19-69`.
However, `ProcessSupervisor` is `@MainActor` at
`apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift:79-80` and calls
`keyStore.readKey()` synchronously at `:222-228`. The production implementation
reaches synchronous `SecItemCopyMatching` at
`apps/hippocampus/Sources/HippocampusKit/KeyStore.swift:81-91`. ACL evaluation,
Keychain lock state, or user interaction can therefore still freeze the menu-bar UI
during every startup and capture transition.

Required repair: perform the final typed Keychain read/validation off MainActor and
return only its result to actor-isolated state. Add a responsiveness test around a
delayed/interaction-blocked Keychain client.

#### P1-5: Production child launchers still propagate ambient reusable keys

The shared supervisor sanitizer is correct, but it is not used by every production
child as required by Task 2 step 7a. Onboarding launches `mci-agent register-mcp`
without assigning `Process.environment` at
`apps/onboarding/Sources/OnboardingKit/ClaudeCodeRegistrar.swift:87-96`, and its
database-reading `mci-agent stats` probe does the same at
`apps/onboarding/Sources/OnboardingKit/NativeHostDeliveryProbe.swift:42-57`.
Additional app children inherit unchanged environment, including `/usr/bin/tccutil`
and `/bin/bash`, at `apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift:347-370`.

Thus a production executable launched with `MCI_DB_KEY_HEX`, `MCI_DB_KEY_FILE`, or
`MCI_DEVELOPMENT_FILE_KEY` propagates that reusable material into further process
environments even though the main supervisor's helper/agent path is clean.

Required repair: centralize a content-free child environment helper in a shared
module and apply it to every production `Process` construction. Add process-level
tests that launch a fixture child and inspect the environment it actually receives.

### P2

#### P2-1: Existing-item ACL state is neither verified nor truthfully audited

An existing readable Keychain item returns `AlreadyPresent` without checking the
four-consumer ACL at `apps/agent/src/key_resolver.rs:426-449`. The native adapter
can only read data or add a new item at
`adapters/macos/mci-keychain/src/lib.rs:107-198`; it has no access-copy or authorized
ACL migration path. Nevertheless, the app reports a four-executable `SecAccess`
ACL whenever it can read the value at
`apps/hippocampus/Sources/HippocampusKit/KeyWrapAudit.swift:48-75`.

An item readable by Hippocampus or `mci-agent` but missing Recall/helper trust is
therefore reported as healthy. The audit tests use only a fake data read at
`apps/hippocampus/Tests/HippocampusKitTests/KeyWrapAuditTests.swift:7-50`.

Required repair: inspect the real file-Keychain item's access object and report
observed ACL state. If the expected stable-code requirements are absent, fail
closed and provide an explicit user-authorized ACL migration that preserves the
secret; do not silently replace or update key bytes.

#### P2-2: The follow-up runner can wait forever after cancellation

`96496ed` bounds retained diagnostics and drains the pipe concurrently, but
cancellation sends only `Process.terminate()` at
`apps/hippocampus/Sources/HippocampusKit/KeyCustodyCommandRunner.swift:127-135` and
then waits without a deadline at `:55-59`. A child that ignores or cannot complete
SIGTERM leaves the detached task and custody operation alive indefinitely. There is
also a narrow cancellation handoff after `wasCancelled` is sampled at `:61-68`,
where a cancellation can arrive and a successful result can still be returned.
The fixture uses cooperative `/bin/sleep` at
`scripts/test-agent-key-custody-runner.sh:56-73`.

Required repair: use a bounded TERM grace period followed by SIGKILL, await verified
process death, and check cancellation again after the detached result is joined.
Test a SIGTERM-resistant child, cancel-before-install, cancel-after-exit, launch
failure under cancellation, and absence of a surviving PID.

#### P2-3: User-facing gate documentation still names removed ambient authority

`ARCHITECTURE.md:118` and `CHANGELOG.md:28-29` still say live capture requires
`HIPPOCAMPUS_ENABLE_V2P1=1` and that migration is pending. Production code ignores
that variable and uses persisted `capture_enabled` translated to `--capture`.
These documents direct operators toward a gate that intentionally no longer works
and contradict the shipped custody state.

Required repair: document the persisted toggle, generation-bound readiness, and
the exact remaining on-device verification status; remove the legacy environment
instruction.

#### P2-4: Release-critical tests remain structural at the boundaries where failures occur

Migration state-machine tests use a recording validator and a marker file at
`apps/agent/tests/key_resolver.rs:91-127`; the one real SQLCipher validator test at
`:130-147` is not composed with migration. Supervisor tests discard real process
exit callbacks as noted above. ACL packaging tests inspect source strings at
`apps/agent/tests/keychain_packaging_contract.rs:28-128`, and the Key Wrap audit
uses a fake client. These tests can all pass while P1-1, P1-3, and P2-1 remain.

Required repair: add end-to-end migration tests over a real SQLCipher database,
process/generation tests with actual termination callbacks, and a signed two-build
Keychain ACL upgrade test that exercises all four consumers.

### P3

No P3 finding.

## Gate

**FAIL.** `a821f65` plus `96496ed` substantially improves key custody, typed errors,
capture-off behavior, and startup responsiveness, but P1-1 through P1-5 are release
blockers. Task 2 is not ready to merge or ship as the security gate.

## Verified Evidence

- `cargo test -p mci-agent --test key_resolver --locked`: PASS, 19/19.
- `cargo test -p mci-agent --locked`: PASS. The library reported 333 passed and one
  documented model-dependent ignore; all binary/integration suites, including 9
  packaging-contract and 13 MCP-registration tests, passed.
- `scripts/test-agent-key-custody-runner.sh` at `96496ed`: PASS for MainActor
  responsiveness, bounded noisy stderr, and cooperative-child cancellation.
- `scripts/swift-package.sh build --package-path apps/hippocampus` at `96496ed`:
  PASS. It emitted existing deprecation/concurrency warnings but no build error.
- Focused Task 2 Swift test files for helper, app, and onboarding: `swiftc -parse`
  PASS.
- `scripts/swift-package.sh test --package-path apps/hippocampus`: BLOCKED before
  test execution because the Command Line Tools Swift build cannot import `XCTest`.
- The remaining helper package build was stopped on request and returned 130; no
  result is claimed. Onboarding and Recall package builds were not rerun in R2.

Source audit also confirms these positive properties: production helper/agent/MCP
launch plans do not place the database key in argv or generated MCP configuration;
Keychain missing/denied/interaction/generic failures are distinct; database-exists
legacy migration validates before plaintext deletion; ambient
`HIPPOCAMPUS_ENABLE_V2P1` alone cannot construct capture resources; capture-off
does not construct `SCStream`, context readers, OCR, or blob writers; readiness is
published only after Keychain resolution and successful `SCStream.startCapture()`;
release signing scripts require a stable Developer ID; and Recall selects a
configuration-specific staged Rust archive.

## Exact Unverified Owner Gates

1. On a physical macOS machine with full Xcode, run the app/helper/onboarding/Recall
   Swift XCTest suites, then complete release-configuration builds for all four
   Keychain consumers.
2. With two separately built, notarizable releases signed by the same Developer ID,
   create/migrate the key in version N, install version N+1, and prove Hippocampus,
   `MCICaptureHelper`, `mci-agent`, and Recall each read the same item without an
   unexpected prompt. Inspect and record the actual ACL/code requirements.
3. Exercise real Security.framework outcomes for missing item, locked Keychain,
   denied access, user-cancelled interaction, malformed material, duplicate-add
   race, and interrupted post-add validation. Include both no-database legacy
   states and two consecutive launches.
4. On a TCC-capable physical Mac, prove capture-off under direct helper launch and
   ambient legacy gate injection produces no ScreenCaptureKit access, context read,
   OCR, or blob write. Then prove capture-on readiness only after live frames can
   start, plus TCC denial, helper/agent early exit, persistence failure, and
   rollback/retry overlap with generation identity recorded.
5. Extend and run the `96496ed` process fixture with a SIGTERM-resistant child and
   verify TERM-to-KILL escalation, prompt cancellation, bounded diagnostics, and no
   surviving child PID.
