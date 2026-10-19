#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${1:-debug}"

# Rust otherwise stamps native objects with the build host's current macOS
# version. Recall links this archive into an app that supports macOS 14, so
# every C/Rust object in the archive must carry the same minimum target.
export MACOSX_DEPLOYMENT_TARGET=14.0

case "$PROFILE" in
    debug)
        cargo build --locked -p mci-brain-ffi
        ;;
    release)
        cargo build --locked -p mci-brain-ffi --release
        ;;
    *)
        printf 'stage-recall-ffi.sh: profile must be debug or release\n' >&2
        exit 64
        ;;
esac

SOURCE="$REPO_ROOT/target/$PROFILE/libmci_brain_ffi.a"
DESTINATION_DIR="$REPO_ROOT/apps/recall-ui/.build/mci-brain-ffi/$PROFILE"
DESTINATION="$DESTINATION_DIR/libmci_brain_ffi.a"

if [[ ! -f "$SOURCE" ]]; then
    printf 'stage-recall-ffi.sh: Cargo did not produce %s\n' "$SOURCE" >&2
    exit 1
fi

mkdir -p "$DESTINATION_DIR"
# SwiftPM never sees the archive as an input: when only the Rust code changed,
# it keeps every product linked against the old archive, and the window and
# its tests run the old reader. So when the archive changes, the products
# linked from it go too (never the compiled objects), and the next build
# links them again against this one.
CHANGED=1
if [[ -f "$DESTINATION" ]] && cmp -s "$SOURCE" "$DESTINATION"; then
    CHANGED=0
fi
TEMP_ARCHIVE="$DESTINATION.tmp.$$"
trap 'rm -f "$TEMP_ARCHIVE"' EXIT
install -m 0644 "$SOURCE" "$TEMP_ARCHIVE"
mv -f "$TEMP_ARCHIVE" "$DESTINATION"
cmp -s "$SOURCE" "$DESTINATION" || {
    printf 'stage-recall-ffi.sh: staged archive verification failed\n' >&2
    exit 1
}
if [[ "$CHANGED" == 1 ]]; then
    for products in "$REPO_ROOT"/apps/recall-ui/.build/*-apple-macosx*/"$PROFILE"; do
        [[ -d "$products" ]] || continue
        find "$products" -maxdepth 1 \( -type f -perm -0100 -o -type d -name '*.xctest' \) -exec rm -rf {} +
    done
fi
