#!/usr/bin/env bash
set -euo pipefail

# strip-release-binaries.sh — Make release binaries smaller without changing
# what they do.
#
#   scripts/strip-release-binaries.sh [--symbols-dir DIR] BINARY...
#
# For each Mach-O binary, in place:
#   1. With --symbols-dir, when the binary still has debug information, write
#      DIR/<name>.dSYM with dsymutil first, so its crash reports can still be
#      read later (a dSYM matches its binary by UUID).
#   2. Run `strip -x` on a copy: the local symbol table goes, exported
#      symbols, code and data stay. strip keeps the linker's ad-hoc signature
#      valid; build-app.sh signs the app it assembles anyway.
#   3. Check the copy has the binary's UUID, architectures, minimum macOS and
#      every library it loads, weak or strong (so hippocampus-mind still
#      weak-links FoundationModels), then put it in the binary's place.
#
# The release scripts run this on the Swift products before build-app.sh
# copies them into the app. Rust binaries come out of `cargo build --release`
# already stripped ([profile.release] in Cargo.toml).
#
# HIPPOCAMPUS_STRIP_TOOL replaces /usr/bin/strip, for the fixture test only.

usage() {
    sed -n '4,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SYMBOLS_DIR=""
BINARIES=()
STRIP_TOOL="${HIPPOCAMPUS_STRIP_TOOL:-/usr/bin/strip}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --symbols-dir) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; SYMBOLS_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "strip-release-binaries: unknown option $1" >&2; exit 2 ;;
        *) BINARIES+=("$1"); shift ;;
    esac
done
[[ ${#BINARIES[@]} -gt 0 ]] || { usage >&2; exit 2; }

die() { echo "strip-release-binaries: $*" >&2; exit 1; }

# What must not change: identity, architectures, minimum macOS and SDK, and
# every library and search path the binary loads.
load_signature() {
    {
        /usr/bin/lipo -archs "$1"
        /usr/bin/otool -l "$1" | awk '
            $1 == "cmd" { cmd = $2; next }
            cmd ~ /^LC_(LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB|ID_DYLIB|RPATH)$/ \
                && ($1 == "name" || $1 == "path") { print cmd, $2 }
            cmd == "LC_BUILD_VERSION" && ($1 == "platform" || $1 == "minos" || $1 == "sdk") { print cmd, $1, $2 }
            cmd == "LC_UUID" && $1 == "uuid" { print cmd, $2 }'
    } 2>/dev/null
}

# Read dsymutil's whole symbol table before searching it: `grep -q` stops at
# the first match, and under pipefail dsymutil's SIGPIPE on a large binary
# would read as "no debug information".
has_debug_map() {
    local table
    table="$(/usr/bin/dsymutil -s "$1" 2>/dev/null || true)"
    grep -q 'N_OSO' <<<"$table"
}

size_of() { stat -f%z "$1"; }

if [[ -n "$SYMBOLS_DIR" ]]; then mkdir -p "$SYMBOLS_DIR"; fi
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/strip-release-binaries.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

total_before=0
total_after=0
for binary in "${BINARIES[@]}"; do
    [[ -f "$binary" && ! -L "$binary" ]] || die "not a regular file: $binary"
    /usr/bin/file -b "$binary" | grep -q 'Mach-O' || die "not a Mach-O binary: $binary"
    name="$(basename "$binary")"
    before="$(size_of "$binary")"
    expected="$(load_signature "$binary")"
    grep -q '^LC_UUID ' <<<"$expected" || die "$name has no UUID, so a dSYM could never be matched to it"

    if [[ -n "$SYMBOLS_DIR" ]] && has_debug_map "$binary"; then
        /usr/bin/dsymutil "$binary" -o "$SYMBOLS_DIR/$name.dSYM" 2>"$SCRATCH/dsymutil.log" \
            || { cat "$SCRATCH/dsymutil.log" >&2; die "dsymutil failed for $name"; }
        dsym_uuids="$(/usr/bin/dwarfdump --uuid "$SYMBOLS_DIR/$name.dSYM" | awk '{ print $2 }' | sort)"
        binary_uuids="$(/usr/bin/dwarfdump --uuid "$binary" | awk '{ print $2 }' | sort)"
        [[ -n "$dsym_uuids" && "$dsym_uuids" == "$binary_uuids" ]] \
            || die "the dSYM for $name does not match the binary's UUID"
    fi

    copy="$SCRATCH/$name"
    cp -p "$binary" "$copy"
    "$STRIP_TOOL" -x "$copy" 2>"$SCRATCH/strip.log" || { cat "$SCRATCH/strip.log" >&2; die "strip failed for $name"; }
    [[ "$(load_signature "$copy")" == "$expected" ]] \
        || die "stripping $name changed its UUID, architectures, minimum macOS or loaded libraries"
    after="$(size_of "$copy")"
    mv -f "$copy" "$binary"

    total_before=$((total_before + before))
    total_after=$((total_after + after))
    printf '  %-24s %10d -> %10d bytes\n' "$name" "$before" "$after"
done
printf '  %-24s %10d -> %10d bytes\n' "total" "$total_before" "$total_after"
