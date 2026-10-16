#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_APP="$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
VERIFY_MODELS="$REPO_ROOT/scripts/verify-models.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-app-contract.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

help_output="$($BUILD_APP --help)"
rg -q -- '--development-lite' <<< "$help_output" \
    || fail "build-app help omits --development-lite"

if "$BUILD_APP" --development-lite --dist "$TEST_ROOT/release" \
    > "$TEST_ROOT/release.stdout" 2> "$TEST_ROOT/release.stderr"; then
    fail "release-profile development-lite unexpectedly succeeded"
fi
rg -q 'development-lite.*requires --debug' "$TEST_ROOT/release.stdout" "$TEST_ROOT/release.stderr" \
    || fail "development-lite did not fail closed outside debug"

if "$BUILD_APP" --debug --development-lite --dist "$TEST_ROOT/unsigned" \
    > "$TEST_ROOT/unsigned.stdout" 2> "$TEST_ROOT/unsigned.stderr"; then
    fail "unsigned development-lite unexpectedly succeeded"
fi
rg -q 'development-lite.*requires --development-ad-hoc' \
    "$TEST_ROOT/unsigned.stdout" "$TEST_ROOT/unsigned.stderr" \
    || fail "development-lite did not require explicit ad-hoc signing"

rg -q 'if \[\[ "\$DEVELOPMENT_LITE" -eq 1 \]\]' "$BUILD_APP" \
    || fail "build-app has no explicit development-lite branch"
rg -q 'Release assembly requires a stable Developer ID Application identity' "$BUILD_APP" \
    || fail "release signing refusal was removed"
rg -Fq '"$VERIFY_SCRIPT" --app "$APP" --allow-missing-bundled' "$BUILD_APP" \
    || fail "development-lite does not explicitly authorize missing bundled models"
rg -Fq '"$VERIFY_SCRIPT" --app "$APP"' "$BUILD_APP" \
    || fail "release assembly does not run strict model verification"
if rg -Fq '"$VERIFY_SCRIPT" --app "$APP" || true' "$BUILD_APP"; then
    fail "model verification failures are still swallowed"
fi
rg -q -- '--allow-missing-bundled' "$VERIFY_MODELS" \
    || fail "model verifier has no explicit development-only omission mode"
if rg -Fq 'zero-vector stub fallback' "$VERIFY_MODELS"; then
    fail "model verifier still promises the retired zero-vector fallback"
fi

# The STATUS audit gates apps people are given, not ad-hoc development
# builds. The real build-app.sh runs in a fixture repository whose
# docs/STATUS.md baseline is four commits behind HEAD, with empty files for
# the binaries; each run stops at the first missing input after the gate.
FIXTURE="$TEST_ROOT/status-fixture"
mkdir -p "$FIXTURE/apps/hippocampus/Resources" "$FIXTURE/scripts/lib" "$FIXTURE/docs"
cp "$BUILD_APP" "$REPO_ROOT/apps/hippocampus/Resources/Info.plist" \
    "$REPO_ROOT/apps/hippocampus/Resources/Hippocampus.entitlements" \
    "$FIXTURE/apps/hippocampus/Resources/"
cp "$REPO_ROOT/scripts/lib/app-group-contract.sh" "$FIXTURE/scripts/lib/"
cp "$REPO_ROOT/CHANGELOG.md" "$REPO_ROOT/NOTICE" "$FIXTURE/"
printf 'raise SystemExit(0)\n' > "$FIXTURE/scripts/verify-toml-license-contract.py"
for profile in debug release; do
    for binary in apps/hippocampus/.build/$profile/Hippocampus \
        adapters/macos/MCICaptureHelper/.build/$profile/mci-capture-helper \
        apps/recall-ui/.build/$profile/recall-ui apps/onboarding/.build/$profile/onboarding \
        target/$profile/mci-agent target/$profile/hippocampus-native-host; do
        mkdir -p "$FIXTURE/$(dirname "$binary")"
        : > "$FIXTURE/$binary"
    done
done
fixture_git() {
    git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false "$@"
}
fixture_git -c init.defaultBranch=main init -q
fixture_git add -A
fixture_git commit -q -m baseline
printf 'Audited code baseline: `%s`\n' "$(fixture_git rev-parse HEAD)" > "$FIXTURE/docs/STATUS.md"
fixture_git add docs/STATUS.md
fixture_git commit -q -m status
for n in 1 2 3; do
    fixture_git commit -q --allow-empty -m "later $n"
done
fixture_build() {
    local name="$1"
    shift
    if env -u APPLE_TEAM_ID -u NOTARYTOOL_TEAM_ID \
        DEVELOPER_ID='Developer ID Application: Fixture (ABCDE12345)' \
        "$FIXTURE/apps/hippocampus/Resources/build-app.sh" "$@" --dist "$TEST_ROOT/$name" \
        > "$TEST_ROOT/$name.out" 2>&1; then
        fail "the $name fixture unexpectedly assembled an app"
    fi
}

fixture_build ad-hoc --debug --development-ad-hoc --development-lite
rg -q 'audit baseline not required for an ad-hoc development build' "$TEST_ROOT/ad-hoc.out" \
    || fail "an ad-hoc development build still requires a fresh STATUS audit"
rg -q 'FATAL: models\.json missing' "$TEST_ROOT/ad-hoc.out" \
    || fail "the ad-hoc fixture did not continue past the STATUS gate"

fixture_build developer-id --debug
rg -q 'audit baseline is 4 commits behind HEAD; maximum is 3' "$TEST_ROOT/developer-id.out" \
    || fail "a Developer ID build did not stop at a stale STATUS audit"
if rg -q 'models\.json missing' "$TEST_ROOT/developer-id.out"; then
    fail "a Developer ID build continued past a stale STATUS audit"
fi

# A release dry run (release-0.3.0.sh --dry-run) signs with Developer ID but
# skips the STATUS audit, since nothing it makes is notarized or given out.
# The same release build without the flag still stops at the stale audit.
fixture_build release-stale
rg -q 'audit baseline is 4 commits behind HEAD; maximum is 3' "$TEST_ROOT/release-stale.out" \
    || fail "a release build did not stop at a stale STATUS audit"
fixture_build release-dry-run --release-dry-run
rg -q 'audit baseline not checked: release dry run' "$TEST_ROOT/release-dry-run.out" \
    || fail "a release dry run did not say it skips the STATUS audit"
rg -q 'FATAL: models\.json missing' "$TEST_ROOT/release-dry-run.out" \
    || fail "the release dry run fixture did not continue past the STATUS gate"
for combination in --debug --development-ad-hoc; do
    fixture_build "dry-run$combination" --release-dry-run "$combination"
    rg -q -- '--release-dry-run is a release build signed with Developer ID' "$TEST_ROOT/dry-run$combination.out" \
        || fail "--release-dry-run was accepted with $combination"
done

printf 'Audited code baseline: `%s`\n' "$(fixture_git rev-parse HEAD~1)" > "$FIXTURE/docs/STATUS.md"
fixture_build fresh --debug
rg -q 'audit baseline OK' "$TEST_ROOT/fresh.out" \
    || fail "a Developer ID build refused a fresh STATUS audit"

printf 'PASS: development app mode is explicit and release-fail-closed\n'
