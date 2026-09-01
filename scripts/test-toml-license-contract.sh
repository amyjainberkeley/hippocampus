#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFIER="$REPO_ROOT/scripts/verify-toml-license-contract.py"

PASS_COUNT=0
FAIL_COUNT=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

expect_accept() {
    local root="$1" message="$2"
    if PYTHONDONTWRITEBYTECODE=1 python3 "$VERIFIER" --repo-root "$root" >/dev/null 2>&1; then
        pass "$message"
    else
        fail "$message"
    fi
}

expect_reject() {
    local root="$1" expected="$2" message="$3" output
    if output=$(PYTHONDONTWRITEBYTECODE=1 python3 "$VERIFIER" --repo-root "$root" 2>&1); then
        fail "$message"
    elif printf '%s\n' "$output" | rg -Fq -- "$expected"; then
        pass "$message"
    else
        fail "$message (unexpected diagnostic: $output)"
    fi
}

make_fixture() {
    local name="$1"
    local root="$TMP_DIR/$name"
    mkdir -p "$root/apps/hippocampus" "$root/third_party/licenses"
    cp "$REPO_ROOT/apps/hippocampus/Package.swift" "$root/apps/hippocampus/Package.swift"
    cp "$REPO_ROOT/apps/hippocampus/Package.resolved" "$root/apps/hippocampus/Package.resolved"
    cp "$REPO_ROOT/NOTICE" "$root/NOTICE"
    cp "$REPO_ROOT/third_party/licenses/toml-license-manifest.json" "$root/third_party/licenses/"
    cp "$REPO_ROOT/third_party/licenses/TOMLKit-0.6.0-LICENSE.txt" "$root/third_party/licenses/"
    cp "$REPO_ROOT/third_party/licenses/tomlplusplus-3.4.0-LICENSE.txt" "$root/third_party/licenses/"
    printf '%s\n' "$root"
}

for required in \
    "$VERIFIER" \
    "$REPO_ROOT/third_party/licenses/toml-license-manifest.json" \
    "$REPO_ROOT/third_party/licenses/TOMLKit-0.6.0-LICENSE.txt" \
    "$REPO_ROOT/third_party/licenses/tomlplusplus-3.4.0-LICENSE.txt"; do
    if [[ ! -f "$required" ]]; then
        fail "required license-contract input exists: ${required#$REPO_ROOT/}"
    fi
done
if [[ "$FAIL_COUNT" -ne 0 ]]; then
    printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
    exit 1
fi

expect_accept "$REPO_ROOT" 'reviewed pinned TOML license contract is complete'

fixture="$(make_fixture missing-permission)"
python3 - "$fixture/third_party/licenses/TOMLKit-0.6.0-LICENSE.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("Permission is hereby granted", "Permission was removed", 1))
PY
expect_reject "$fixture" 'missing required MIT text: Permission is hereby granted' \
    'missing MIT permission grant is rejected by the clause gate'

fixture="$(make_fixture missing-warranty)"
python3 - "$fixture/third_party/licenses/tomlplusplus-3.4.0-LICENSE.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace('THE SOFTWARE IS PROVIDED "AS IS"', "Warranty text was removed", 1))
PY
expect_reject "$fixture" 'missing required MIT text: THE SOFTWARE IS PROVIDED' \
    'missing MIT warranty disclaimer is rejected by the clause gate'

fixture="$(make_fixture pin-drift)"
python3 - "$fixture/apps/hippocampus/Package.resolved" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    "ec6198d37d495efc6acd4dffbd262cdca7ff9b3f",
    "0000000000000000000000000000000000000000",
    1,
))
PY
expect_reject "$fixture" 'Package.resolved TOMLKit identity, URL, version, or revision drifted' \
    'resolved TOMLKit revision drift is rejected'

fixture="$(make_fixture notice-drift)"
python3 - "$fixture/NOTICE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("Permission is hereby granted", "Permission was removed", 1))
PY
expect_reject "$fixture" 'NOTICE must contain exactly one complete canonical TOMLKit license' \
    'shipped NOTICE drift is rejected'

fixture="$(make_fixture missing-license)"
rm "$fixture/third_party/licenses/tomlplusplus-3.4.0-LICENSE.txt"
expect_reject "$fixture" 'cannot read' 'missing canonical bundled license is rejected'

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
