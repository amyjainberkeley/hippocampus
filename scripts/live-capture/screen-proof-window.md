# Screen-Only Qualification Window

This standalone native fixture is not shipped in Hippocampus. It has no brain,
Keychain, capture, import or network access. It generates twelve random words
only after an explicit **Generate once** click while the application is active,
its window is key, and the system foreground PID matches the fixture. Twelve
independent selections from 32 words provide 60 bits of randomness. The phrase
exists only in fixture memory and its visible native text view. User edits are
rejected without changing the text view's native focus or AX text behavior.
Window restoration is disabled. Never copy, save, print, import or paste the
phrase into a console, tool argument, clipboard or agent conversation.

## Build And Launch

The owner or main task performs the approved genuine UI run. From the worktree,
build a disposable bundle in a new directory; do not overwrite an existing
fixture or change the installed Hippocampus app:

```sh
cd /Users/amy/hippo-work/hippocampus/.worktrees/hippocampus-v1
proof_dir="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-screen-proof.XXXXXX")"
proof_app="$proof_dir/Hippocampus Screen Proof.app"
mkdir -p "$proof_app/Contents/MacOS"
xcrun swiftc -swift-version 6 -warnings-as-errors -O \
  scripts/live-capture/ScreenProofExposure.swift \
  scripts/live-capture/ScreenProofReceipt.swift \
  scripts/live-capture/ScreenProofWindow.swift \
  -o "$proof_app/Contents/MacOS/ScreenProofWindow"
cp scripts/live-capture/ScreenProofWindow-Info.plist "$proof_app/Contents/Info.plist"
codesign --force --sign - "$proof_app"
```

Launch only when ready to interact. The observation deadline is 120 seconds
after fixture startup, including time before generation. LaunchServices keeps
normal app activation semantics; stdout goes directly to a content-free local
receipt file, separate from AppKit's stderr diagnostics:

```sh
open -n --stdout "$proof_dir/receipts.jsonl" --stderr "$proof_dir/stderr.log" "$proof_app"
```

No new Screen Recording, Accessibility or Automation grant is required by the
fixture. It only reads numeric WindowServer metadata and the system foreground
PID. Do not grant/reset permissions or relax capture exclusions for this test.
Existing permissions of an owner-approved UI controller are a separate matter.

## Genuine UI Workflow

1. Read `fixture_ready` from the receipt file to identify the fixture PID and
   window number. This record may show inactive state immediately after launch;
   it acknowledges the fixture, not successful foreground activation.
2. Bring the fixture forward using normal approved UI. Address its window and
   controls by the stable identifiers below. Before generation, confirm the
   latest receipt has both system PIDs equal to `fixture_pid`, the normal
   WindowServer window equal to `fixture_window_number`, and a key, visible,
   active AppKit window. Do not enumerate AX values or capture an AX tree that
   includes the phrase after it is generated.
3. Click `screen-proof.generate` exactly once. Require one `phrase_generated`
   record, its hash, and its `generated_at_us` as the generation boundary.
   Generation focuses the text view. If needed, click `screen-proof.phrase`
   without reading its AX value, copying text or typing replacement text.
4. Leave the fixture visible. Observe only the content-free receipt file from
   a background reader; do not switch to a terminal or controller window to
   inspect progress. Require an `exposure_observation` with the same hash,
   `continuous_seconds` equal to 20, and `foreground.exposure_eligible` true.
   If foreground identity is lost, the counter resets. Stop the automated
   attempt on that loss; keep its receipts and do not regenerate automatically.
   Any later attempt with a new phrase must have a separate explicit UI click
   and a separate receipt file. No auto-activation loop holds focus forcibly.
5. At the deadline, observation stops, Generate is disabled, and a single
   `observation_finished` record has `foreground: null` and zero seconds. This
   is a terminal status, not success. A suspended run loop may deliver this
   terminal record later; it performs no further metadata query on resumption.
   The window stays open until the owner closes it. A missing terminal record
   after early close/crash is an incomplete session, not a passing one.

| Element | AX identifier |
| --- | --- |
| Window | `screen-proof.window` |
| Generate button | `screen-proof.generate` |
| Phrase text view | `screen-proof.phrase` |
| Exposure status | `screen-proof.exposure` |

## Receipt Contract

Schema version 2 is JSONL. Every line has `schema_version`,
`record_type`, `observed_at_us`, `phrase_sha256`, `continuous_seconds` and
`foreground`. `phrase_sha256` is null before generation, then a lowercase
64-digit SHA-256 commitment. Only `phrase_generated` also has
`generated_at_us`, equal to that record's `observed_at_us`, preserving the
generation-boundary field from version 1. No other fields are emitted. No
phrase, AX value, app name, private title, URL, path or screenshot is serialized.
Invalid hash strings are rejected before serialization.

`foreground` distinguishes these sources:

| Fields | Meaning |
| --- | --- |
| `fixture_pid`, `fixture_window_number` | This process's PID and its AppKit window number. |
| `system_frontmost_pid_before`, `system_frontmost_pid_after` | `NSWorkspace.frontmostApplication` PID before/after the WindowServer query; missing values are null. |
| `system_frontmost_pid_stable` | Both PID reads are present and equal; these are samples, not an atomic snapshot. |
| `system_frontmost_normal_window_number` | First on-screen layer-0 window owned by that stable system foreground PID, in WindowServer front-to-back order; unavailable or racing identity is null. |
| `window_server_query_succeeded` | Whether on-screen window metadata was available. |
| `window_server_fixture_window_found` | The on-screen list contains both this fixture's PID and its window number. |
| `app_was_active`, `window_was_key`, `window_was_visible`, `text_was_focused` | Independent AppKit observations. Visible also requires not minimized and a visible occlusion state. |
| `exposure_eligible` | System PID/window identity matches this fixture and all four AppKit observations are true. |

The system PID comes from [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication).
Window numbers and layers come from [WindowServer metadata](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)).
The fixture never requests pixels or reads other applications' titles or text.
Numeric metadata is available without relying on protected window names; see
[Apple's window-metadata guidance](https://developer.apple.com/videos/play/wwdc2019/701/).

The normal window number is **stacking evidence, not system AX focused-window
identity**. Panels, sheets, occlusion and changes between samples can make those
different. There is deliberately no claimed `system_focused_window_number`.
Production capture still independently resolves and admits its AX-focused
window. A metadata match does not qualify that production decision.

A one-second timer samples at most once per elapsed-second slot, up to 120
samples, including `fixture_ready`. Other pre-generation samples use
`foreground_observation`; post-generation samples use `exposure_observation`.
The explicit generation click adds at most one metadata sample and receipt;
the terminal receipt performs no query. A run emits at most 122 receipt lines.
Observation does not retry failed metadata reads. Unknown or changed identity
resets exposure, as do AppKit focus loss and sampling gaps over two seconds.
Neither timers nor receipts prove uninterrupted visibility between samples.

## Capture Qualification

Twenty observed seconds are only fixture evidence. Search actual newly
captured records by fixture source and time after the generation boundary;
never seed a query or import with the displayed phrase. Normalize only the
captured line breaks to spaces and compare the local SHA-256 with the receipt.
Require fresh `screen_ocr` provenance, the correct fixture identity, and an
authenticated encrypted image containing the same visible phrase. Close the
fixture before restarting Recall and reopening that same event and image.
The owner-approved client must retrieve the same evidence. Missing text,
images, identity or readback leaves [Gate 1](../../docs/audits/2026-09-07-observable-gates.md)
open. No source-kind rewrite, exclusion bypass, stale event, unrelated image
or growing aggregate counter qualifies the gate.

The older `verify_production_memory.py` uses fixed probes and cannot read
images. It is not a validator for this random screen-only fixture.

## Headless Regression

```sh
bash scripts/live-capture/test-screen-proof.sh
```

This typechecks the normal fixture entry point and runs only the exposure,
native text-view and receipt regressions. It uses synthetic numeric metadata
and fixed test text, opens no window, performs no live foreground queries,
generates no proof phrase, and requests no capture or AX permission. Tests
cover foreground mismatch/races/absence, bounded observation, native text
integrity, stable control identifiers and the exact receipt field allowlist.
Disposable test binaries are removed automatically. A genuine UI run remains
the responsibility of the owner or main task.
