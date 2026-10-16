#!/usr/bin/env bash
set -euo pipefail

# test-strip-release-binaries.sh — strip-release-binaries.sh makes a binary
# smaller and changes nothing it does, keeps a dSYM that matches it, and
# refuses to replace a binary when stripping would change how it loads.
# Builds a small C fixture; touches no release binary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIPPER="$SCRIPT_DIR/strip-release-binaries.sh"
TMP_ROOT="$(mktemp -d -t hippocampus-strip-release)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check() {
    local message="$1"; shift
    if "$@" >>"$TMP_ROOT/check.log" 2>&1; then pass "$message"; else fail "$message"; fi
}
refuses() {
    local message="$1"; shift
    if "$@" >>"$TMP_ROOT/check.log" 2>&1; then fail "$message"; else pass "$message"; fi
}

# Thousands of functions, as in the real products: dsymutil's symbol table
# for such a binary is far longer than a pipe holds, so a check that stops
# reading it early is caught here.
{
    printf '#include <stdio.h>\n\n'
    for index in $(seq 1 3000); do
        printf 'int filler_function_%d(int v) { return v + %d; }\n' "$index" "$index"
    done
} >"$TMP_ROOT/filler.c"
cat >"$TMP_ROOT/fixture.c" <<'C'
#include <stdio.h>

static int local_helper_for_strip_fixture(int value) { return value * 7 + 3; }

int exported_for_strip_fixture(int value) { return local_helper_for_strip_fixture(value); }

int main(int argc, char **argv) {
    printf("fixture %d %s\n", exported_for_strip_fixture(argc), argc > 1 ? argv[1] : "-");
    return 0;
}
C

# As the Swift release products are linked: debug information in the object
# files, a weak framework link and an rpath.
build_fixture() {
    local output="$1"
    xcrun clang -g -O0 -mmacosx-version-min=14.0 -c "$TMP_ROOT/fixture.c" -o "$TMP_ROOT/fixture.o"
    xcrun clang -g -O0 -mmacosx-version-min=14.0 -c "$TMP_ROOT/filler.c" -o "$TMP_ROOT/filler.o"
    xcrun clang -g -mmacosx-version-min=14.0 "$TMP_ROOT/fixture.o" "$TMP_ROOT/filler.o" -o "$output" \
        -Wl,-weak_framework,CoreFoundation -Wl,-rpath,@executable_path/../Frameworks
}

# Whole outputs are read before they are searched, here as in the stripper.
has_symbol() { local table; table="$(nm "$1" 2>/dev/null || true)"; grep -q "$2" <<<"$table"; }

linkage() {
    otool -l "$1" | awk '
        $1 == "cmd" { cmd = $2; next }
        cmd ~ /^LC_(LOAD_DYLIB|LOAD_WEAK_DYLIB|RPATH)$/ && ($1 == "name" || $1 == "path") { print cmd, $2 }
        cmd == "LC_BUILD_VERSION" && $1 == "minos" { print cmd, $2 }'
}
uuid_of() { dwarfdump --uuid "$1" | awk '{ print $2 }'; }

BIN="$TMP_ROOT/bin/fixture"
ORIGINAL="$TMP_ROOT/original"
SYMBOLS="$TMP_ROOT/symbols"
mkdir -p "$TMP_ROOT/bin"
build_fixture "$BIN"
cp -p "$BIN" "$ORIGINAL"

# The fixture is what the test needs it to be.
has_symbol "$BIN" 'local_helper_for_strip_fixture' || { echo 'fixture has no local symbol' >&2; exit 1; }
[[ "$(dsymutil -s "$BIN" | wc -c)" -gt 1000000 ]] || { echo 'fixture symbol table is too short to fill a pipe' >&2; exit 1; }
linkage "$BIN" | grep -q 'LC_LOAD_WEAK_DYLIB .*CoreFoundation' || { echo 'fixture has no weak link' >&2; exit 1; }

check 'the stripper runs on a binary with debug information' \
    "$STRIPPER" --symbols-dir "$SYMBOLS" "$BIN"

if [[ "$(stat -f%z "$BIN")" -lt "$(stat -f%z "$ORIGINAL")" ]]; then
    pass 'the stripped binary is smaller'
else
    fail 'the stripped binary is smaller'
fi
if has_symbol "$BIN" 'local_helper_for_strip_fixture'; then
    fail 'local symbols are gone'
else
    pass 'local symbols are gone'
fi
EXPORTS="$(nm -g "$BIN")"
if grep -q '_exported_for_strip_fixture' <<<"$EXPORTS" && grep -q '_main' <<<"$EXPORTS"; then
    pass 'exported symbols stay'
else
    fail 'exported symbols stay'
fi
if [[ "$(linkage "$BIN")" == "$(linkage "$ORIGINAL")" ]]; then
    pass 'the weak link, rpath and minimum macOS are unchanged'
else
    fail 'the weak link, rpath and minimum macOS are unchanged'
fi
if [[ "$(uuid_of "$BIN")" == "$(uuid_of "$ORIGINAL")" ]]; then
    pass 'the UUID is unchanged, so the dSYM still matches'
else
    fail 'the UUID is unchanged, so the dSYM still matches'
fi
check 'the stripped binary is still validly signed (ad hoc, as linked)' codesign --verify --strict "$BIN"
if [[ "$("$BIN" probe)" == "$("$ORIGINAL" probe)" ]]; then
    pass 'the stripped binary does exactly what the original did'
else
    fail 'the stripped binary does exactly what the original did'
fi
if [[ "$(uuid_of "$SYMBOLS/fixture.dSYM")" == "$(uuid_of "$ORIGINAL")" ]]; then
    pass 'the dSYM was written and matches the binary'
else
    fail 'the dSYM was written and matches the binary'
fi
DSYM_INFO="$(dwarfdump --debug-info "$SYMBOLS/fixture.dSYM" 2>/dev/null || true)"
if grep -q local_helper_for_strip_fixture <<<"$DSYM_INFO"; then
    pass 'the dSYM still names the local function, for reading crash reports'
else
    fail 'the dSYM still names the local function, for reading crash reports'
fi

SIZE="$(stat -f%z "$BIN")"
check 'stripping again is harmless' "$STRIPPER" "$BIN"
if [[ "$(stat -f%z "$BIN")" == "$SIZE" ]]; then
    pass 'a stripped binary is left as it is'
else
    fail 'a stripped binary is left as it is'
fi

# A strip that would change how the binary loads must not replace it.
cat >"$TMP_ROOT/bad-strip" <<'BAD'
#!/bin/sh
/usr/bin/strip "$@" || exit 1
for last; do :; done
exec /usr/bin/install_name_tool -delete_rpath @executable_path/../Frameworks "$last"
BAD
chmod +x "$TMP_ROOT/bad-strip"
build_fixture "$BIN"
cp -p "$BIN" "$ORIGINAL"
refuses 'a strip that drops an rpath is refused' \
    env HIPPOCAMPUS_STRIP_TOOL="$TMP_ROOT/bad-strip" "$STRIPPER" "$BIN"
if cmp -s "$BIN" "$ORIGINAL"; then
    pass 'a refused binary is left exactly as it was'
else
    fail 'a refused binary is left exactly as it was'
fi

printf 'not a binary' >"$TMP_ROOT/notes.txt"
refuses 'a file that is not Mach-O is refused' "$STRIPPER" "$TMP_ROOT/notes.txt"
ln -s "$BIN" "$TMP_ROOT/link"
refuses 'a symlink is refused, so the real file is never stripped by surprise' "$STRIPPER" "$TMP_ROOT/link"

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
    cat "$TMP_ROOT/check.log" >&2
    exit 1
fi
