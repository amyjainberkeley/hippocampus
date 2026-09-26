# Capture Status Contract

The Rust agent atomically writes the content-free receipt at
`~/Library/Application Support/MCI/capture-status.json`:

```json
{
  "schema_version": 1,
  "updated_at": "2026-09-05T12:30:00Z",
  "last_stored_frame_at": null,
  "stored_frame_count": 0,
  "stored_screenshot_count": 0,
  "suppression_reason": null,
  "blocked_reason": null
}
```

Counts represent committed, retained storage. The last stored timestamp may
be null when there are no saved frames. Timestamps accept RFC3339 with or
without fractional seconds. A storage heartbeat must update independently
of whether screen deduplication produces another stored frame.

The UI never derives successful capture from helper delivery/drain counts.
The receipt must be no more than 120 seconds old and updated during the
current supervisor run. Active saving additionally requires a committed
frame during that run within the last 10 minutes. With older saved content,
a fresh current-run helper heartbeat produces the neutral "No recent
changes" state. Missing, invalid, future-dated, or stale evidence cannot
produce active saving. Counts shown from an old receipt are explicitly
described as the last report. Permission, privacy suppression, and storage
failures take precedence over recent saved content.

Retention uses `ninetyDays` for the fresh 90-day default. Explicit setting
saves write `schema_version: 2` to `retention.json`. Existing finite policies
without version 2 remain selected and display "Needs review"; automatic
migration of legacy UserDefaults preserves the selection without adding
version 2. Capture is independent of retention review. Existing `forever`
does not need review.

Normal launch and onboarding completion request Recall's Today (`now`)
view once. `activateTopology` consumes the request after key custody,
readiness, and capture consent have committed. Reopen requests coalesce
during startup and use the existing Recall activation path when ready or
paused; no sleep is used to guess readiness.

## Verification

The standalone readiness-gate behavior check and wrapper Swift parsing
passed locally. Cold package builds were stopped at the parent's request
for centralized compilation; full XCTest and current-revision app linking
remain to be run there. Focused suites:

- Hippocampus: `CaptureStatusReceiptTests`, `HealthSnapshotTests`,
  `MenuBarStatusTests`, `MenuBarQuickActionsTests`, `PreferencesStoreTests`,
  `TCCRevokedRecoveryTests`, `CapturePreferenceControllerTests`, and
  `RecallPresentationGateTests`.
- Onboarding: `DiskRetentionStoreTests` and `RetentionViewModelTests`.
- Retention fixtures: `RetentionPreferencesBehavior` and
  `RetentionPersistenceBehavior`, each with a fresh temporary directory.

The standalone gate check executes production sources via the wrapper:

```sh
cat apps/hippocampus/Sources/HippocampusKit/SupervisorState.swift \
  apps/hippocampus/Sources/HippocampusKit/RecallPresentationGate.swift \
  apps/hippocampus/Tests/Standalone/RecallPresentationBehavior.swift \
  | scripts/swift-package.sh -
```
