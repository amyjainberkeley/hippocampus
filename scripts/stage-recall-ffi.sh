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
TEMP_ARCHIVE="$DESTINATION.tmp.$$"
trap 'rm -f "$TEMP_ARCHIVE"' EXIT
install -m 0644 "$SOURCE" "$TEMP_ARCHIVE"
mv -f "$TEMP_ARCHIVE" "$DESTINATION"
cmp -s "$SOURCE" "$DESTINATION" || {
    printf 'stage-recall-ffi.sh: staged archive verification failed\n' >&2
    exit 1
}
