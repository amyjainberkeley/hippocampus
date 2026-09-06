# Hippocampus: Built, Proven, And Still Missing

This ledger distinguishes source implementation from installed verification.
`docs/STATUS.md` remains canonical release truth. No public release is authorized
by a local build, and no test result establishes zero bugs or malware immunity.

## This Integration

- **Capture safety:** late errors from retired streams no longer kill their
  replacements. An explicit macOS capture stop is distinguished from a runtime
  failure and disables capture instead of triggering automatic restart.
- **Visible failures:** disabling capture attempts persistence, consent revocation
  and child shutdown independently. A failure stays visible in the menu, with
  capture-off intent latched for this parent session. Failed disk persistence
  cannot promise that intent survives a later relaunch.
- **Quiet input:** one read-only OS idle-duration query lowers processing cadence
  to a sample every ten seconds after sixty seconds without input. A new window
  or resumed input is admitted immediately. All privacy gates still apply. This
  is not a keylogger, an attention detector or measured working-time telemetry.
- **Daily drafts:** source-preserving excerpts are ranked into changes, open
  loops and recent activity. Repeated OCR and recognized system chrome are
  reduced; differing wording and numbers are not silently merged. Drafts are
  local, model-free, at most nine bullets and 16 KB after escaping.
- **Evidence navigation:** native briefs show inert, readable source text with
  an icon to open the saved event and its authenticated screenshot, when present.
  Captured markup cannot create navigation controls. Malformed and overflowing
  citation markers have tests, including a reproduced and repaired empty-marker
  crash. Old/unknown brief formats remain plain text.
- **Release hygiene:** patched the known `anyhow` advisory, scanned both tracked
  Rust lockfiles, pinned the scanner, tied release auditing to the exact tag and
  made model/launch checks mandatory. The existing unmaintained `paste` waiver
  remains visible. No unrelated dependency upgrades were made.

## Verification

Optimized native suites passed: capture 674; parent 307; Recall 402 XCTest plus
three Swift Testing handoff cases. The ten-case synthetic brief corpus improved
from 2/10 to 10/10 on its declared relevance/source-containment rubric, with
18/18 labeled source excerpts retained. The unchanged eight-day corpus passes.
These tests do not establish semantic truth or universal injection resistance.

The initial full debug Rust run hit two tier2 timing limits while native builds
were competing for CPU. Its failure is retained; quiet recheck and final signed
installed proof are pending. The known-good installed app remains `fe285ee`
until its successor is assembled and verified. See the continuation plan for
test logs, precise scope and remaining acceptance gates.

## Not Yet Finished

1. Live new-build capture, image, search, brief and agent-context proof; then
   safe replacement of the known-good installed app and signed installer.
2. Real normal/private-browser qualification and owner-controlled permission
   revoke/restore and macOS Stop tests. Never reset or grant these automatically.
3. Measured active/idle/unknown activity persisted through a versioned contract.
   Screen spans or quiet sampling must not be displayed as hours worked.
4. Source-bound commitment candidates with explicit confirm/dismiss/done, source
   deletion handling and a held-out false-positive evaluation. No automatic
   actions based on guessed obligations.
5. Qualified generative understanding and trusted answers. Current context is
   observations, not verified facts; no silent external inference is enabled.
6. Second-Mac install/update/Keychain continuity, complete reproducible model
   inputs, broader source/dependency security coverage and independent review.
   The public release model manifest remains UNPROVISIONED.

These are real gaps in the larger vision, not a hidden claim that V1/V2/V3 is
complete. The next work stays ordered by capture reliability, evidence quality,
user control, measured usefulness and only then broader autonomy.
