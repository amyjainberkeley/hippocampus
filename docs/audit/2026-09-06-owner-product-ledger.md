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
- **Recovery follow-up:** live testing found replacement startup could fail with
  `noDisplay` and silently abandon recovery. Bounded retries now continue across
  replacement startup failures; wake can recover an eligible failed session.
  An independent code reviewer found permission/Quit races and two related
  state regressions. Behavioral tests reproduced them before correction.
  Revoked access blocks capture startup, not a successful pause; a dead child
  remains visibly failed. Quit intent survives failed teardown until app restart.
- **Search follow-up:** restored queries load on opening Search; typing starts a
  bounded debounced query. Superseded successes and errors cannot replace newer
  results, resurrect cleared results or override explicitly opened evidence.
- **Summary follow-up:** Finder gallery counters, metadata and OCR icon fragments
  no longer fill daily-brief slots. Finder preview excerpts require recognized
  work-activity wording. This conservative filter can omit unfamiliar prose;
  original events and images are retained.

## Verification

Optimized native suites passed: capture 674; parent 323; Recall 409 XCTest plus
three Swift Testing handoff cases. The ten-case synthetic brief corpus improved
from 2/10 to 10/10 on its declared relevance/source-containment rubric, with
18/18 labeled source excerpts retained. The unchanged eight-day corpus passes.
These tests do not establish semantic truth or universal injection resistance.

The final serial full debug Rust workspace passed 1,972 tests, with nine ignored.
The initial concurrent-build run's two timing failures remain recorded; the
release-mode test-key-wrap guard was not bypassed. Eight release-safety fixtures,
16 audit fixtures and 224 release-contract checks passed. A separate reviewer
reported no remaining actionable findings in the corrected recovery diff.
This is not a whole-product independent security audit.

Signed/notarized/stapled `11194ae` is installed. Synthetic TextEdit event 1755
passed the real screen -> encrypted image -> native Search/viewer -> Codex MCP
loop. Its durable screenshot proof and installer live in
`/Users/amy/hippo-work/releases/2026-09-06-11194ae/`.
Capture later became disconnected after replacement startup failed, so that
earlier positive proof is not a claim of uninterrupted capture.

The follow-up is now installed as signed/notarized/stapled **`2e5fc82`**. Fresh
TextEdit event 1802 reached real Codex MCP. Terminating only the owned helper
produced a disconnected receipt, then a replacement generation saved event 1803
about three seconds later. Native screenshot display, restored-query loading,
typing without Enter and brief-to-source navigation passed on that artifact.
The native draft no longer includes Finder gallery metadata, but still has
clipped/repeated OCR excerpts. It is an evidence draft, not a finished intelligent
work summary. Screenshots and installer are preserved in
`/Users/amy/hippo-work/releases/2026-09-06-2e5fc82/`.

After normal parent relaunch, TextEdit event 1806 also reached Codex. The final
Now view showed 182 stored screen records / 72 screenshots, and one owned
helper/agent generation was running. The app is left open; short-run proof is
not a claim of uninterrupted overnight reliability.

The build-only `8b8598b` follow-up makes installer launch verification use a
disposable home and require first-run onboarding. The same clean-home test
passed independently on the notarized binary. See `docs/STATUS.md` for artifact
hashes and the continuation plan for the remaining acceptance gates.

## Not Yet Finished

1. Longer installed sleep/wake/ordinary-work qualification and clearer, less
   repetitive briefs with complete source context. The positive installed loop
   passes; this is not yet broad reliability or semantic-quality qualification.
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
