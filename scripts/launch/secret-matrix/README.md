# secret-matrix

A runnable launch check for one claim: **Hippocampus skips or refuses the
sensitive things on a fixed list before it stores anything.** It is an outside
judge — synthetic screens run through the real shipping policy code, with
assertions that fail the build if a drop regresses — not a self-assessment.

## Run

```sh
env -i HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
  PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  nice -n 15 scripts/launch/secret-matrix/run.sh
```

It writes `eval/secret-matrix-2026-10-17.md` and exits non-zero if any provable
row failed.

## What it drives (no copies of the policy)

- **Swift** (`SecretMatrixTests.swift`, in the capture-helper test target):
  renders each case as the cascade's own input — app bundle id, window title,
  URL, OCR lines, and the three OS signals (secure-input bit, focused-AX
  subrole, OS-blacked region) — and runs the real `SuppressionCascade`,
  `SensitiveCaptureDenylist`, and `BrowserPixelCapturePolicy` with
  `.ordinaryApplications` admission (the production posture from
  `Sources/MCICaptureHelper/main.swift`).
- **Rust** (`core/brain` redaction crate + `tests/reading.rs`): the Messages/Mail
  ingest redaction (`sms_otp`, `messages_plugin`, `sensitive_domains`), the OCR
  secret shapes (`ocr_secrets`: the four key/token patterns, the Luhn credit-card
  check, and the keyword-context OTP check), and the Swift↔Rust parity guard.

## Files

- `run.sh` — orchestrates both engines, renders the matrix, gates on failures.
- `render.py` — turns the Swift TSV + the Rust pass/fail into the Markdown
  matrix. Deterministic (no timestamps), so a clean run leaves the tree clean.
  Run via `python3 -I`.
- The Swift cases live in
  `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/SecretMatrixTests.swift`
  so they compile and run inside the existing test target and can cite the
  neighbouring suites (`NeverReadPasswordManagersTests`, `BrowserPrivateWindowTests`, …).

## Privacy

Every input is invented. No screenshot is taken, no real memory is read, no app
is launched, nothing is published.

## Adding a case

1. Add a row to `SecretMatrixTests.testSecretMatrix` (assert the drop; append a
   `Row`). If it is a real gap, add an ignored `testGAP_*` with `XCTSkip` and a
   note, and record the row as `NEEDS-A-PERSON` — never weaken a rule to make a
   row pass.
2. If it is a Rust-side (ingest) case, cite the `core/brain` test in
   `render.py`'s `rust_rows`.
3. Re-run `run.sh`.
