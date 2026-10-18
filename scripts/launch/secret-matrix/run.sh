#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# run.sh — the launch secret-matrix harness.
#
# Proves, on SYNTHETIC screens, that Hippocampus skips or refuses the sensitive
# cases in eval/secret-matrix-<date>.md before anything is stored. It drives the
# REAL shipping policy code (no copies):
#   - Rust: the redaction crate (sms_otp, messages_plugin, sensitive_domains,
#     ocr_secrets) and the cross-engine parity test (core/brain/tests/reading.rs).
#   - Swift: SecretMatrixTests (+ the corroborating suites it cites), which run
#     the capture helper's SuppressionCascade / SensitiveCaptureDenylist /
#     BrowserPixelCapturePolicy on each case.
# It then renders eval/secret-matrix-<date>.md and EXITS NON-ZERO if any
# provable row failed. It is an outside judge, not a self-assessment.
#
# Privacy: every input is invented. No screenshot is taken, no real memory is
# read, no app is launched, nothing is published.
#
# Run it sandboxed, exactly as documented in the generated matrix:
#   env -i HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" LANG=en_US.UTF-8 \
#     PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
#     nice -n 15 scripts/launch/secret-matrix/run.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DATE="2026-10-17"
PKG="$REPO/adapters/macos/MCICaptureHelper"
OUT_MD="$REPO/eval/secret-matrix-$DATE.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/secret-matrix.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TSV="$WORK/swift-matrix.tsv"

say() { printf '\n=== %s ===\n' "$1"; }
status_of() { [ "$1" -eq 0 ] && echo PASS || echo FAIL; }

# --- 1. Rust: redaction unit tests -----------------------------------------
say "Rust redaction unit tests (sms_otp / messages_plugin / sensitive_domains / ocr_secrets)"
nice -n 15 cargo test --manifest-path "$REPO/Cargo.toml" -p mci-brain --lib redaction:: \
    >"$WORK/rust-redaction.log" 2>&1
RUST_REDACTION="$(status_of $?)"
tail -1 "$WORK/rust-redaction.log"

# --- 2. Rust: cross-engine secret parity -----------------------------------
say "Rust cross-engine parity (core/brain/tests/reading.rs)"
nice -n 15 cargo test --manifest-path "$REPO/Cargo.toml" -p mci-brain --test reading \
    >"$WORK/rust-reading.log" 2>&1
RUST_READING="$(status_of $?)"
tail -1 "$WORK/rust-reading.log"

# --- 3. Swift: build the capture-helper test target ------------------------
say "Swift build (capture helper test target)"
nice -n 15 "$REPO/scripts/swift-package.sh" build --build-tests --package-path "$PKG" \
    >"$WORK/swift-build.log" 2>&1
SWIFT_BUILD=$?
tail -1 "$WORK/swift-build.log"
if [ "$SWIFT_BUILD" -ne 0 ]; then
    echo "Swift build failed; see $WORK/swift-build.log" >&2
    cat "$WORK/swift-build.log" >&2
    exit 1
fi

# --- 4. Swift: the matrix itself -------------------------------------------
say "Swift secret matrix (SecretMatrixTests)"
SECRET_MATRIX_OUT="$TSV" nice -n 15 "$REPO/scripts/swift-package.sh" test \
    --package-path "$PKG" --filter SecretMatrixTests \
    >"$WORK/swift-matrix.log" 2>&1
SWIFT_MATRIX="$(status_of $?)"
grep -E "Executed .* tests" "$WORK/swift-matrix.log" | tail -1

# --- 5. Swift: corroborating suites cited in the matrix --------------------
say "Swift corroborating suites (NeverReadPasswordManagers / Denylist / BrowserPrivateWindow / SuppressionCascade / ConcreteProbes)"
nice -n 15 "$REPO/scripts/swift-package.sh" test --package-path "$PKG" \
    --filter 'NeverReadPasswordManagersTests' \
    --filter 'DenylistTests' \
    --filter 'BrowserPrivateWindowTests' \
    --filter 'Cascade.*Tests' \
    --filter 'ConcreteProbe' \
    >"$WORK/swift-cited.log" 2>&1
SWIFT_CITED="$(status_of $?)"
grep -E "Executed .* tests" "$WORK/swift-cited.log" | tail -1

if [ ! -s "$TSV" ]; then
    echo "matrix TSV was not written ($TSV); Swift matrix run failed" >&2
    cat "$WORK/swift-matrix.log" >&2
    exit 1
fi

# --- 6. Render the committed matrix ----------------------------------------
say "Render $OUT_MD"
mkdir -p "$(dirname "$OUT_MD")"
python3 -I "$HERE/render.py" \
    --tsv "$TSV" --out "$OUT_MD" \
    --rust-redaction "$RUST_REDACTION" \
    --rust-reading "$RUST_READING" \
    --swift-matrix "$SWIFT_MATRIX" \
    --swift-cited "$SWIFT_CITED"
RENDER=$?

# --- 7. Gate ---------------------------------------------------------------
say "Summary"
printf '  rust redaction : %s\n' "$RUST_REDACTION"
printf '  rust parity    : %s\n' "$RUST_READING"
printf '  swift matrix   : %s\n' "$SWIFT_MATRIX"
printf '  swift cited    : %s\n' "$SWIFT_CITED"
printf '  matrix written : %s\n' "$OUT_MD"

if [ "$RUST_REDACTION" = PASS ] && [ "$RUST_READING" = PASS ] \
    && [ "$SWIFT_MATRIX" = PASS ] && [ "$SWIFT_CITED" = PASS ] && [ "$RENDER" -eq 0 ]; then
    echo "  gate           : PASS (all provable rows dropped the secret)"
    exit 0
fi
echo "  gate           : FAIL (a provable row regressed — see the matrix and logs in $WORK)" >&2
exit 1
