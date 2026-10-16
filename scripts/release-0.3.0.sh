#!/usr/bin/env bash
set -euo pipefail

# release-0.3.0.sh — Build, sign, notarize and verify Hippocampus 0.3.0 on this Mac.
#
#   scripts/release-0.3.0.sh --check   # every quick gate; builds and commits nothing
#   scripts/release-0.3.0.sh --dry-run # build and sign here; notarize, commit, open nothing
#   scripts/release-0.3.0.sh           # the release
#
# The release, in order, stopping at the first failure:
#   1. Preflight: branch, clean tree, release identity, CHANGELOG, Cargo.lock,
#      models, OCR worker, toolchain, Developer ID, notary profile, Sparkle
#      key, installer assets, installer Python, power and disk. Nothing
#      changes if it fails.
#   2. Set up the installer's Python (two hashed wheels from PyPI) if needed.
#   3. Rebuild the offline OCR worker if it no longer matches tools/ocr.
#   4. Stamp docs/STATUS.md with HEAD and commit "docs(status): release baseline".
#   5. Build release binaries: cargo, then the five Swift packages, including
#      hippocampus-mind. Strip their local symbols, keeping dSYMs in
#      <out>/symbols for reading crash reports.
#   6. Assemble and sign Hippocampus.app (apps/hippocampus/Resources/build-app.sh).
#   7. Make, sign, notarize and staple the DMG (scripts/build-installer.sh).
#   8. Verify the DMG and the app inside it; print the DMG path and SHA-256.
#   9. Sign the DMG for Sparkle and write appcast.xml from the CHANGELOG
#      section, with the feed itself signed (scripts/sparkle-publish.sh and
#      Sparkle's sign_update, using the Sparkle key file), then check it with
#      the release identity gate.
#
# The app's update feed (SUFeedURL) is the appcast.xml of the newest
# published GitHub release. Uploading appcast.xml with the DMG, and
# publishing that release as Latest, is what shows installed copies the
# update; no other host is involved.
#
# Steps 6 and 7 each open the new app for 20 seconds under a throwaway home
# (the launch check), so its setup window shows on screen twice. Steps 2, 6
# and 7 use the network (PyPI, Apple's timestamp and notary services).
# Nothing is pushed, tagged or uploaded.
#
# release-models.json is not read here: it names the model archive the
# tag-triggered CI release downloads. This build bundles models/ from this Mac.
#
# A dry run (--dry-run) builds and signs everything as the release does,
# with the Developer ID and the Sparkle key, from any branch. It sends
# nothing to Apple's notary service, stamps and commits nothing, and never
# opens the app (no launch check). It verifies every signature, runs
# syspolicy_check notary-submission (the notary service's own checks), and
# reports what Gatekeeper says of an app that is not notarized, then prints
# the sizes. Its files are for inspection only: never upload them.
#
# Options:
#   --check           Run the preflight only.
#   --dry-run         The dry run above (default output:
#                     ~/Hippocampus-release-candidates/0.3.0-dry-run).
#   --out DIR         Where the DMG, logs and installer Python go
#                     (default: ~/Hippocampus-release-candidates/0.3.0).
#   --notes FILE      Release notes containing {{SHA256}}; a filled copy is
#                     written beside the DMG as release-notes.md.
#   --jobs N          Parallel build jobs (default: 4).
#   --sparkle-key FILE  The Sparkle EdDSA private key file, mode 600
#                     (default: ~/.hippocampus-sparkle-private.key).
#   --allow-low-disk  Start even when free disk is below this run's estimate.
#                     Each heavy stage still stops below 1.5 GB.
#
# Environment:
#   HIPPOCAMPUS_RELEASE_EXTRA_PATH  Directories placed first on the build PATH,
#                                   for example one that holds rg.

RELEASE_VERSION="0.3.0"
RELEASE_TAG="v$RELEASE_VERSION"
RELEASE_BRANCH="claude/hippocampus-0.3"
TEAM_ID="BV6KGKFKP4"
NOTARY_PROFILE="notarytool-profile"
STAMP_SUBJECT="docs(status): release baseline"
CO_AUTHOR="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
MIN_FREE_MB=1536
MINIMUM_MACOS="14.0"
REPOSITORY="amyjainberkeley/hippocampus"
SWIFT_PACKAGES="apps/hippocampus adapters/macos/MCICaptureHelper apps/recall-ui apps/onboarding apps/mind"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO_ROOT/apps/hippocampus/dist/Hippocampus.app"
STATUS_FILE="$REPO_ROOT/docs/STATUS.md"
DMG_LAYOUT="$REPO_ROOT/assets/installer/dmg-layout.py"
INSTALLER_REQUIREMENTS="$REPO_ROOT/scripts/installer-requirements.txt"
OCR_DIR="$REPO_ROOT/tools/ocr"
OCR_PYTHON="$OCR_DIR/.venv/bin/python"
EMBEDDER="$REPO_ROOT/models/ArcticEmbedS_FP16.mlmodelc"
INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
SIGN_UPDATE="$REPO_ROOT/apps/hippocampus/.build/artifacts/sparkle/Sparkle/bin/sign_update"

CHECK_ONLY=0
DRY_RUN=0
ALLOW_LOW_DISK=0
JOBS=4
OUT_DIR=""
NOTES_FILE=""
SPARKLE_KEY="$HOME/.hippocampus-sparkle-private.key"

usage() {
    # The header comment, from line 4 to the first line that is not one.
    awk 'NR < 4 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --out) [[ $# -ge 2 ]] || { usage; exit 2; }; OUT_DIR="$2"; shift 2 ;;
        --notes) [[ $# -ge 2 ]] || { usage; exit 2; }; NOTES_FILE="$2"; shift 2 ;;
        --jobs) [[ $# -ge 2 ]] || { usage; exit 2; }; JOBS="$2"; shift 2 ;;
        --sparkle-key) [[ $# -ge 2 ]] || { usage; exit 2; }; SPARKLE_KEY="$2"; shift 2 ;;
        --allow-low-disk) ALLOW_LOW_DISK=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs needs a positive number" >&2; exit 2; }
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$HOME/Hippocampus-release-candidates/$RELEASE_VERSION"
    if [[ "$DRY_RUN" -eq 1 ]]; then OUT_DIR="$OUT_DIR-dry-run"; fi
fi
[[ "$OUT_DIR" == /* ]] || OUT_DIR="$PWD/$OUT_DIR"

# What a dry run does differently, in one place.
if [[ "$DRY_RUN" -eq 1 ]]; then
    ASSEMBLY_MODE=(--release-dry-run)  # build-app.sh: no STATUS audit, no launch check
    INSTALLER_MODE=(--dry-run)         # build-installer.sh: not notarized, no launch check
    GATEKEEPER_CHECK="notary-submission"
else
    ASSEMBLY_MODE=()
    INSTALLER_MODE=()
    GATEKEEPER_CHECK="distribution"
fi
[[ "$SPARKLE_KEY" == /* ]] || SPARKLE_KEY="$PWD/$SPARKLE_KEY"
if [[ -n "$NOTES_FILE" ]]; then
    [[ "$NOTES_FILE" == /* ]] || NOTES_FILE="$PWD/$NOTES_FILE"
    [[ -f "$NOTES_FILE" ]] || { echo "No notes file at $NOTES_FILE" >&2; exit 2; }
fi

LOG_DIR="$OUT_DIR/logs"
SYMBOLS_DIR="$OUT_DIR/symbols"
DIST_DIR="$OUT_DIR/installer"
INSTALLER_VENV="$OUT_DIR/installer-python"
DMG="$DIST_DIR/Hippocampus-$RELEASE_VERSION.dmg"
STABLE_DMG="$DIST_DIR/Hippocampus.dmg"
APPCAST="$DIST_DIR/appcast.xml"
REPO_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"

# Every build step runs in this environment and nothing else: no provider
# keys, tokens or other credentials reach the build.
BUILD_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin"
if [[ -n "${HIPPOCAMPUS_RELEASE_EXTRA_PATH:-}" ]]; then
    BUILD_PATH="$HIPPOCAMPUS_RELEASE_EXTRA_PATH:$BUILD_PATH"
fi
BUILD_TMPDIR="${TMPDIR:-/tmp}"

clean_env() {
    /usr/bin/env -i HOME="$HOME" PATH="$BUILD_PATH" TMPDIR="$BUILD_TMPDIR" LANG=en_US.UTF-8 "$@"
}

say() { printf '%s\n' "$*"; }

stop() {
    printf '\nSTOPPED: %s\n' "$*" >&2
    exit 1
}

VERIFY_MOUNT_ROOT=""
on_exit() {
    local status=$?
    if [[ -n "$VERIFY_MOUNT_ROOT" ]]; then
        /usr/bin/hdiutil detach "$VERIFY_MOUNT_ROOT/volume" -quiet >/dev/null 2>&1 \
            || /usr/bin/hdiutil detach "$VERIFY_MOUNT_ROOT/volume" -force -quiet >/dev/null 2>&1 || true
        rmdir "$VERIFY_MOUNT_ROOT/volume" "$VERIFY_MOUNT_ROOT" 2>/dev/null || true
    fi
    exit "$status"
}
trap on_exit EXIT
trap 'stop "Interrupted."' INT TERM

# --- Disk ---

existing_parent() {
    local path="$1"
    while [[ ! -d "$path" ]]; do path="$(dirname "$path")"; done
    printf '%s\n' "$path"
}

free_mb_at() {
    /bin/df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'
}

# The smaller of the free space where the build runs and where the DMG goes.
free_mb() {
    local repo out
    repo="$(free_mb_at "$REPO_ROOT")"
    out="$(free_mb_at "$(existing_parent "$OUT_DIR")")"
    if (( repo < out )); then printf '%s\n' "$repo"; else printf '%s\n' "$out"; fi
}

gb() { awk -v mb="$1" 'BEGIN { printf "%.1f", mb / 1024 }'; }

require_disk() {
    local free
    free="$(free_mb)"
    if (( free < MIN_FREE_MB )); then
        stop "Only $(gb "$free") GB free before \"$1\". The release stops below 1.5 GB. Free some space and run this script again; finished stages are reused."
    fi
}

# --- Stages ---

stage() {
    local title="$1" log="$LOG_DIR/$2.log" started
    shift 2
    started="$(date +%s)"
    say "== $(date +%H:%M:%S) $title"
    say "   log: $log"
    if ! /usr/bin/nice -n 5 /usr/bin/env -i HOME="$HOME" PATH="$BUILD_PATH" \
        TMPDIR="$BUILD_TMPDIR" LANG=en_US.UTF-8 "$@" >"$log" 2>&1; then
        printf -- '--- last 40 lines of %s ---\n' "$log" >&2
        tail -n 40 "$log" >&2 || true
        stop "$title failed. Full log: $log"
    fi
    say "   done in $(( $(date +%s) - started ))s, $(gb "$(free_mb)") GB free"
}

# --- Small checks shared by the preflight and the release ---

head_sha() { git -C "$REPO_ROOT" rev-parse HEAD; }

tree_changes() { git -C "$REPO_ROOT" status --porcelain --untracked-files=normal; }

require_clean_tree() {
    local changes
    changes="$(tree_changes)"
    [[ -z "$changes" ]] || stop "$1 The tree changed: $(printf '%s\n' "$changes" | sed -n 1p). Nothing more was built."
}

# The repository's own release identity gate: tag, bundle version and build,
# minimum macOS, Sparkle feed and key, CHANGELOG and (after the stamp) the
# STATUS baseline. Its model-archive check belongs to the tag-triggered CI.
release_identity() {
    clean_env python3 -B - "$REPO_ROOT" "$RELEASE_TAG" "$1" <<'PY'
import sys
from pathlib import Path

root, tag, phase = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
sys.path.insert(0, str(root / "scripts"))
import verify_release_identity as identity

identity.load_and_validate = lambda *args, **kwargs: None
if phase == "before-stamp":
    identity.validate_status_audit = lambda *args, **kwargs: None
try:
    found = identity.validate_prebuild(root, tag)
except identity.ReleaseIdentityError as error:
    print(error)
    sys.exit(1)
print(f"{tag}: bundle {found['version']} build {found['build']}, macOS {found['minimum_system']} or later")
PY
}

# The same gate over what will be uploaded: DMG name, checksum, the appcast
# item, the DMG's Sparkle signature and the feed's own signature, both under
# the app's SUPublicEDKey.
release_identity_staged() {
    clean_env python3 -B - "$REPO_ROOT" "$RELEASE_TAG" "$DMG" "$APPCAST" "$REPOSITORY" "$DRY_RUN" <<'PY'
import sys
from pathlib import Path

root, tag, dmg, appcast, repository, dry_run = (
    Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]), sys.argv[5], sys.argv[6])
sys.path.insert(0, str(root / "scripts"))
import verify_release_identity as identity

identity.load_and_validate = lambda *args, **kwargs: None
if dry_run == "1":
    # A dry run stamps nothing, so there is no fresh STATUS baseline to check.
    identity.validate_status_audit = lambda *args, **kwargs: None
try:
    found = identity.validate_prebuild(root, tag)
    identity.validate_staged(root, tag, found, dmg, appcast, repository)
except identity.ReleaseIdentityError as error:
    print(error)
    sys.exit(1)
print(f"appcast.xml offers {tag} (build {found['build']}); the DMG's and the feed's signatures verify with SUPublicEDKey")
PY
}

status_baseline() {
    [[ -f "$STATUS_FILE" ]] || return 0
    # shellcheck disable=SC2016  # the backticks are Markdown, matched literally
    sed -nE 's/^Audited code baseline: `([0-9a-fA-F]{7,40})`.*$/\1/p' "$STATUS_FILE" | sed -n 1p
}

ocr_is_fresh() {
    clean_env python3 -B -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import bundle
bundle.verify_runtime(Path(sys.argv[2]))
' "$OCR_DIR" "$OCR_DIR/dist/hippocampus-ocr" >/dev/null 2>&1
}

# What prepare.py needs before it freezes the worker, without the network.
ocr_is_rebuildable() {
    [[ -x "$OCR_PYTHON" ]] || return 1
    clean_env "$OCR_PYTHON" -B -c '
import hashlib, importlib.metadata, sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(root))
from worker import MODELS
import PyInstaller
for line in (root / "requirements.in").read_text().splitlines():
    name, version = line.split("==")
    assert importlib.metadata.version(name) == version, name
for name, digest in MODELS.items():
    path = root / "models" / name
    assert path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, name
' "$OCR_DIR" >/dev/null 2>&1
}

installer_python_ready() {
    [[ -x "$INSTALLER_VENV/bin/python" ]] \
        && clean_env "$INSTALLER_VENV/bin/python" -B "$DMG_LAYOUT" --check-dependencies >/dev/null 2>&1
}

find_python_310() {
    local candidate
    for candidate in "$OCR_PYTHON" /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
        if [[ -x "$candidate" ]] && "$candidate" -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

version_at_most() {
    /usr/bin/python3 -c 'import sys; a, b = ([int(p) for p in (v.split(".") + ["0", "0"])[:3]] for v in sys.argv[1:3]); sys.exit(0 if a <= b else 1)' "$1" "$2"
}

estimate_mb() {
    local total="$MIN_FREE_MB" pkg
    ocr_is_fresh || total=$((total + 400))
    if [[ -x "$REPO_ROOT/target/release/mci-agent" ]]; then total=$((total + 200)); else total=$((total + 1000)); fi
    for pkg in $SWIFT_PACKAGES; do
        if [[ -d "$REPO_ROOT/$pkg/.build/release" ]]; then total=$((total + 50)); else total=$((total + 300)); fi
    done
    if [[ -d "$APP" ]]; then total=$((total + 50)); else total=$((total + 450)); fi
    # App archive for notarization, DMG staging copy, writable image, final DMG.
    printf '%s\n' "$((total + 1300))"
}

# --- Preflight ---

FAILURES=0
DEVELOPER_ID=""
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
info() { printf '  info  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# The release asks Apple's notary service for this profile's history; a dry
# run contacts no Apple service about notarization at all.
check_notary_profile() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "notary profile '$NOTARY_PROFILE' not used: a dry run sends nothing to Apple's notary service"
    elif clean_env xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        ok "notary keychain profile '$NOTARY_PROFILE' works"
    else
        fail "notary keychain profile '$NOTARY_PROFILE' does not work (or Apple's service is unreachable)"
    fi
}

preflight() {
    local branch changes count result baseline sdk tool missing identities power percent free need

    if [[ "$DRY_RUN" -eq 1 ]]; then
        say "=== Hippocampus $RELEASE_VERSION release preflight (dry run) ==="
    else
        say "=== Hippocampus $RELEASE_VERSION release preflight ==="
    fi
    say "Repository: $REPO_ROOT"
    say "Output:     $OUT_DIR"

    branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$branch" == "$RELEASE_BRANCH" ]]; then
        ok "branch $RELEASE_BRANCH at $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        info "branch ${branch:-a detached HEAD} at $(git -C "$REPO_ROOT" rev-parse --short HEAD); a dry run builds any branch, the release only $RELEASE_BRANCH"
    else
        fail "branch is ${branch:-a detached HEAD}, not $RELEASE_BRANCH"
    fi

    changes="$(tree_changes)"
    if [[ -z "$changes" ]]; then
        ok "no uncommitted changes"
    else
        count="$(printf '%s\n' "$changes" | wc -l | tr -d ' ')"
        fail "$count uncommitted change(s), first: $(printf '%s\n' "$changes" | sed -n 1p)"
    fi
    if [[ -e "$REPO_GIT_DIR/index.lock" ]]; then
        fail "another git command holds $REPO_GIT_DIR/index.lock"
    fi

    if result="$(release_identity before-stamp 2>&1)"; then
        ok "release identity: $result"
        ok "CHANGELOG.md has a [$RELEASE_VERSION] section with items"
    else
        fail "release identity: $result"
    fi

    baseline="$(status_baseline)"
    if [[ -n "$baseline" && "$DRY_RUN" -eq 1 ]]; then
        ok "docs/STATUS.md baseline line found ($baseline); a dry run leaves it as it is"
    elif [[ -n "$baseline" ]]; then
        ok "docs/STATUS.md baseline line found ($baseline); it is stamped at HEAD just before the build"
    else
        fail "docs/STATUS.md has no line 'Audited code baseline: \`<sha>\`' to stamp"
    fi

    if result="$(cd "$REPO_ROOT" && clean_env cargo tree --locked --offline \
        -p mci-agent -p hippocampus-native-host -p mci-brain-ffi \
        --target aarch64-apple-darwin -e normal,build --prefix none 2>&1 >/dev/null)"; then
        ok "Cargo.lock is current and every crate the release builds is on this Mac"
    else
        fail "Cargo.lock: $(printf '%s\n' "$result" | tail -1)"
    fi

    if [[ -f "$EMBEDDER/model.mil" && -d "$EMBEDDER/weights" && -f "$EMBEDDER/coremldata.bin" ]]; then
        ok "search model models/ArcticEmbedS_FP16.mlmodelc is complete (bundled as is; nothing is downloaded)"
    else
        fail "models/ArcticEmbedS_FP16.mlmodelc is missing or incomplete"
    fi

    if ocr_is_fresh; then
        ok "OCR worker tools/ocr/dist matches tools/ocr"
    elif ocr_is_rebuildable; then
        warn "OCR worker is stale; the release rebuilds it first (a few minutes, no network)"
    else
        fail "OCR worker is stale and cannot be rebuilt: tools/ocr/.venv or its models are missing (see tools/ocr/README.md)"
    fi

    sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
    if [[ -n "$sdk" ]] && version_at_most 26.0 "$sdk"; then
        ok "macOS SDK $sdk: hippocampus-mind builds with Apple Intelligence support"
    else
        fail "macOS SDK ${sdk:-unknown}: hippocampus-mind needs the macOS 26 SDK"
    fi

    missing=""
    for tool in hdiutil codesign SetFile syspolicy_check ditto shasum spctl otool install_name_tool git python3; do
        clean_env /bin/sh -c "command -v $tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    for tool in notarytool stapler swift; do
        xcrun --find "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if result="$(cd "$REPO_ROOT" && clean_env cargo --version 2>&1)"; then
        ok "toolchain: $result, $(xcrun swift --version 2>/dev/null | sed -n 's/^.*\(Apple Swift version [0-9.]*\).*$/\1/p' | sed -n 1p)"
    else
        missing="$missing cargo"
    fi
    if [[ -n "$missing" ]]; then fail "missing tools:$missing"; else ok "build, signing and disk-image tools found"; fi

    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    DEVELOPER_ID="$(printf '%s\n' "$identities" \
        | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" | sed -n 1p)"
    if [[ -n "$DEVELOPER_ID" ]]; then
        ok "signing identity: $DEVELOPER_ID"
    else
        fail "no Developer ID Application identity for team $TEAM_ID in the keychain"
    fi

    check_notary_profile

    if [[ ! -f "$SPARKLE_KEY" ]]; then
        fail "no Sparkle private key at $SPARKLE_KEY (pass --sparkle-key FILE; scripts/sparkle-keygen.sh made it)"
    elif result="$(clean_env "$REPO_ROOT/scripts/verify-sparkle-keypair.sh" \
        --private-key "$SPARKLE_KEY" --info-plist "$INFO_PLIST" 2>&1)"; then
        ok "Sparkle key $SPARKLE_KEY: $(printf '%s\n' "$result" | tail -1)"
    else
        fail "Sparkle key $SPARKLE_KEY: $(printf '%s\n' "$result" | tail -1)"
    fi
    if [[ -x "$SIGN_UPDATE" ]]; then
        ok "Sparkle's sign_update is in apps/hippocampus/.build, for the appcast"
    else
        info "Sparkle's sign_update arrives when the build resolves apps/hippocampus's packages"
    fi

    if result="$(clean_env "$REPO_ROOT/scripts/build-installer.sh" --verify-assets 2>&1)"; then
        ok "installer icon and license match their sources"
    else
        fail "installer assets: $(printf '%s\n' "$result" | tail -1)"
    fi

    if result="$(clean_env python3 -B "$REPO_ROOT/scripts/verify-toml-license-contract.py" --repo-root "$REPO_ROOT" 2>&1)"; then
        ok "$(printf '%s\n' "$result" | tail -1)"
    else
        fail "TOML licenses: $(printf '%s\n' "$result" | tail -1)"
    fi

    if installer_python_ready; then
        ok "installer Python ready: $INSTALLER_VENV"
    elif result="$(find_python_310)"; then
        warn "installer Python is set up at the start of the release from $result (ds-store 1.3.3 and mac-alias 2.2.3, hashed, from PyPI)"
    else
        fail "no Python 3.10 or later to set up the installer's DMG layout tool"
    fi

    power="$(pmset -g batt 2>/dev/null || true)"
    if printf '%s\n' "$power" | grep -q "Battery Power"; then
        percent="$(printf '%s\n' "$power" | grep -Eo '[0-9]+%' | sed -n 1p | tr -d '%' || true)"
        if [[ -n "$percent" ]] && (( percent < 20 )); then
            fail "on battery at $percent%; plug in before a build of about an hour"
        else
            warn "on battery at ${percent:-?}%; plug in for a build of about an hour"
        fi
    else
        ok "on power adapter"
    fi

    free="$(free_mb)"
    need="$(estimate_mb)"
    if (( free < MIN_FREE_MB )); then
        fail "disk: $(gb "$free") GB free; the release stops below 1.5 GB and this run needs about $(gb "$need") GB"
    elif (( free < need )); then
        if [[ "$ALLOW_LOW_DISK" -eq 1 ]]; then
            warn "disk: $(gb "$free") GB free; this run needs about $(gb "$need") GB (1.5 GB floor included). Each stage still stops below 1.5 GB."
        else
            fail "disk: $(gb "$free") GB free; this run needs about $(gb "$need") GB (1.5 GB floor included). Free space, or pass --allow-low-disk."
        fi
    else
        ok "disk: $(gb "$free") GB free; this run needs about $(gb "$need") GB"
    fi

    if pgrep -f "$APP/Contents/MacOS/" >/dev/null 2>&1; then
        warn "a copy of apps/hippocampus/dist/Hippocampus.app is running; quit it, since assembly replaces it"
    fi
    info "release-models.json is read only by the tag-triggered CI release, which builds nothing while no release secret is set"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "a dry run never opens the new app: the launch checks are skipped"
    else
        info "the launch check opens the new app for 20 s, twice, under a throwaway home"
    fi
}

# --- Release steps ---

provision_installer_python() {
    local base
    if installer_python_ready; then
        say "== installer Python ready: $INSTALLER_VENV"
        return 0
    fi
    base="$(find_python_310)" || stop "No Python 3.10 or later on this Mac for the installer's DMG layout tool."
    if [[ ! -x "$INSTALLER_VENV/bin/python" ]]; then
        stage "installer Python: create $INSTALLER_VENV" installer-python-venv \
            "$base" -m venv "$INSTALLER_VENV"
    fi
    stage "installer Python: ds-store and mac-alias, hashed, from PyPI" installer-python-pip \
        "$INSTALLER_VENV/bin/python" -m pip --isolated install --disable-pip-version-check \
        --index-url https://pypi.org/simple --require-hashes --only-binary=:all: \
        -r "$INSTALLER_REQUIREMENTS"
    installer_python_ready \
        || stop "The installer Python still lacks ds-store 1.3.3 and mac-alias 2.2.3. See $LOG_DIR/installer-python-pip.log."
}

rebuild_ocr_if_stale() {
    if ocr_is_fresh; then
        say "== OCR worker matches tools/ocr; not rebuilt"
        return 0
    fi
    require_disk "rebuild the OCR worker"
    stage "rebuild the OCR worker from tools/ocr/worker.py" ocr-worker \
        "$OCR_PYTHON" "$OCR_DIR/prepare.py"
    ocr_is_fresh || stop "The rebuilt OCR worker still does not match tools/ocr. See $LOG_DIR/ocr-worker.log."
}

commit_status_stamp() {
    local baseline="$1"
    for _ in 1 2 3 4 5 6; do
        if [[ ! -e "$REPO_GIT_DIR/index.lock" ]] && git -C "$REPO_ROOT" commit --quiet \
            -m "$STAMP_SUBJECT" \
            -m "The audited code baseline is now $baseline, the last commit before the $RELEASE_VERSION release build." \
            -m "$CO_AUTHOR" \
            -- docs/STATUS.md; then
            return 0
        fi
        sleep 5
    done
    stop "Could not commit docs/STATUS.md. Undo the stamp with: git -C \"$REPO_ROOT\" checkout -- docs/STATUS.md"
}

stamp_status() {
    local baseline parent result
    baseline="$(status_baseline)"
    parent="$(git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD~1 2>/dev/null || true)"
    if [[ "$(git -C "$REPO_ROOT" log -1 --format=%s)" == "$STAMP_SUBJECT" && -n "$baseline" && -n "$parent" ]] \
        && [[ "$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$baseline^{commit}" 2>/dev/null || true)" == "$parent" ]]; then
        say "== docs/STATUS.md already stamped at $baseline; HEAD is its release baseline commit"
    else
        baseline="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD)"
        say "== stamp docs/STATUS.md at $baseline and commit \"$STAMP_SUBJECT\""
        clean_env python3 -B - "$STATUS_FILE" "$baseline" <<'PY' || stop "Could not stamp docs/STATUS.md."
import re
import sys

path, sha = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
text, count = re.subn(
    r"^(Audited code baseline: `)[0-9a-fA-F]{7,40}(`)",
    lambda match: match.group(1) + sha + match.group(2),
    text,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    sys.exit("docs/STATUS.md has no audited code baseline line")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
        commit_status_stamp "$baseline"
    fi
    result="$(release_identity after-stamp 2>&1)" || stop "Release identity after the stamp: $result"
    say "   $result; STATUS baseline $baseline"
    require_clean_tree "After the stamp."
}

build_binaries() {
    local pkg
    require_disk "cargo build"
    stage "cargo: mci-agent and the browser host (release)" cargo \
        cargo build --release --locked --jobs "$JOBS" -p mci-agent --bins -p hippocampus-native-host

    # A file added since the last release build must not be missed by a
    # stale SwiftPM plan. Touching changes no content, so git and the
    # source digest are unaffected.
    for pkg in $SWIFT_PACKAGES; do touch "$REPO_ROOT/$pkg/Package.swift"; done
    for pkg in $SWIFT_PACKAGES; do
        require_disk "swift build $pkg"
        stage "swift: $pkg (release)" "swift-$(basename "$pkg")" \
            "$REPO_ROOT/scripts/swift-package.sh" build -c release --jobs "$JOBS" --package-path "$REPO_ROOT/$pkg"
    done

    local -a binaries=()
    for pkg in \
        apps/hippocampus/.build/release/Hippocampus \
        adapters/macos/MCICaptureHelper/.build/release/mci-capture-helper \
        target/release/mci-agent \
        target/release/hippocampus-native-host \
        apps/recall-ui/.build/release/recall-ui \
        apps/onboarding/.build/release/onboarding \
        apps/mind/.build/release/hippocampus-mind; do
        [[ -x "$REPO_ROOT/$pkg" ]] || stop "The build did not produce $pkg."
        binaries+=("$REPO_ROOT/$pkg")
    done

    # Smaller binaries, same behaviour: the local symbol table goes (the
    # Rust ones arrive stripped by [profile.release]), and each binary's
    # debug information is kept beside the DMG as a dSYM for crash reports.
    stage "strip local symbols, keeping dSYMs in $SYMBOLS_DIR" strip \
        "$REPO_ROOT/scripts/strip-release-binaries.sh" --symbols-dir "$SYMBOLS_DIR" "${binaries[@]}"
    say "   $(tail -1 "$LOG_DIR/strip.log" | sed 's/^ *//')"
    require_clean_tree "After the build."
}

# What a release app must be, checked as the tag workflow checks it
# (scripts/verify-release-app.sh): hippocampus-mind weak-links
# FoundationModels (otool -l), every binary runs on macOS 14, the version,
# no development file key, a valid signature from this team and, when asked,
# syspolicy_check's verdict.
check_assembled_app() {
    local app="$1" gatekeeper="${2:-none}" result
    if ! result="$(clean_env "$REPO_ROOT/scripts/verify-release-app.sh" --version "$RELEASE_VERSION" \
        --team "$TEAM_ID" --minimum-macos "$MINIMUM_MACOS" --gatekeeper "$gatekeeper" "$app" 2>&1)"; then
        printf '%s\n' "$result" >&2
        stop "$app is not a release app: $(printf '%s\n' "$result" | tail -1 | sed 's/^FAIL  //')"
    fi
    if [[ -n "$VERIFY_LOG" ]]; then printf '\n$ verify-release-app.sh %s\n%s\n' "$app" "$result" >>"$VERIFY_LOG"; fi
}

assemble_app() {
    require_disk "assemble Hippocampus.app"
    [[ "$(head_sha)" == "$RELEASE_HEAD" ]] || stop "HEAD moved during the build. Run this script again."
    local title="assemble and sign Hippocampus.app (includes the 20 s launch check)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        title="assemble and sign Hippocampus.app (dry run: no STATUS audit; the app is not opened)"
    fi
    stage "$title" assemble \
        DEVELOPER_ID="$DEVELOPER_ID" "$REPO_ROOT/apps/hippocampus/Resources/build-app.sh" \
        ${ASSEMBLY_MODE[@]+"${ASSEMBLY_MODE[@]}"}
    check_assembled_app "$APP"
    say "   hippocampus-mind included (FoundationModels weak), every binary runs on macOS $MINIMUM_MACOS, signed by $TEAM_ID"
}

build_dmg() {
    require_disk "make the DMG"
    [[ "$(head_sha)" == "$RELEASE_HEAD" ]] || stop "HEAD moved during the build. Run this script again."
    require_clean_tree "Before the DMG."
    mkdir -p "$DIST_DIR"
    local title="DMG: sign, notarize and staple the app and the DMG (launch check, then Apple's notary service)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        title="DMG: sign the app and the DMG (dry run: not notarized; the app is not opened)"
    fi
    stage "$title" installer \
        DEVELOPER_ID="$DEVELOPER_ID" INSTALLER_PYTHON="$INSTALLER_VENV/bin/python" \
        "$REPO_ROOT/scripts/build-installer.sh" --skip-build --dist "$DIST_DIR" \
        ${INSTALLER_MODE[@]+"${INSTALLER_MODE[@]}"}
    [[ -f "$DMG" && -f "$DMG.sha256" ]] || stop "build-installer.sh finished without $DMG and its .sha256."
}

VERIFY_LOG=""
REPORTS=()

# Gatekeeper rejects an app that is not notarized, so a dry run records what
# it says instead of requiring it to accept.
report() {
    local description="$1" output="" status=0 verdict
    shift
    printf '\n$ %s\n' "$*" >>"$VERIFY_LOG"
    output="$("$@" 2>&1)" || status=$?
    printf '%s\n' "$output" >>"$VERIFY_LOG"
    verdict="$(printf '%s\n' "$output" | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//')"
    REPORTS+=("$description: ${verdict:-no output} (exit $status)")
    say "   report  $description: ${verdict:-no output} (exit $status)"
}

verify() {
    local description="$1"
    shift
    printf '\n$ %s\n' "$*" >>"$VERIFY_LOG"
    if "$@" >>"$VERIFY_LOG" 2>&1; then
        say "   ok  $description"
    else
        printf -- '--- last 20 lines of %s ---\n' "$VERIFY_LOG" >&2
        tail -n 20 "$VERIFY_LOG" >&2 || true
        stop "Verification failed: $description. Full log: $VERIFY_LOG"
    fi
}

verify_release() {
    local mounted app digest
    VERIFY_LOG="$LOG_DIR/verify.log"
    : >"$VERIFY_LOG"
    say "== $(date +%H:%M:%S) verify the DMG and the app inside it"
    say "   log: $VERIFY_LOG"

    verify "checksum file matches the DMG" /bin/sh -c "cd \"$DIST_DIR\" && /usr/bin/shasum -a 256 -c \"$(basename "$DMG").sha256\""
    verify "Hippocampus.dmg is the same bytes, with its own checksum file" /bin/sh -c \
        "/usr/bin/cmp \"$DMG\" \"$STABLE_DMG\" && cd \"$DIST_DIR\" && /usr/bin/shasum -a 256 -c Hippocampus.dmg.sha256"
    verify "hdiutil verify" /usr/bin/hdiutil verify "$DMG"
    verify "DMG signature" /usr/bin/codesign --verify --strict --verbose=2 "$DMG"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        report "Gatekeeper on the DMG (spctl -t open), not notarized" \
            /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    else
        verify "DMG notarization ticket (stapler validate)" /usr/bin/xcrun stapler validate "$DMG"
        verify "Gatekeeper accepts the DMG (spctl -t open)" \
            /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    fi
    verify "the assembled app's signature (deep, strict)" /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        verify "Apple's notary log for the app lists no issues" clean_env python3 -B \
            "$REPO_ROOT/scripts/check-notary-log.py" --archive "Hippocampus-$RELEASE_VERSION-app.zip" "$DIST_DIR/notary-app-log.json"
        verify "Apple's notary log for the DMG lists no issues" clean_env python3 -B \
            "$REPO_ROOT/scripts/check-notary-log.py" --archive "$(basename "$DMG")" "$DIST_DIR/notary-dmg-log.json"
    fi

    VERIFY_MOUNT_ROOT="$(mktemp -d "$BUILD_TMPDIR/hippocampus-release-verify.XXXXXX")"
    mounted="$VERIFY_MOUNT_ROOT/volume"
    mkdir "$mounted"
    verify "the DMG opens read-only" /usr/bin/hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -noverify -mountpoint "$mounted"
    app="$mounted/Hippocampus.app"
    verify "the DMG holds Hippocampus.app and an Applications link" /bin/sh -c "test -d \"$app\" && test -L \"$mounted/Applications\""
    verify "the app in the DMG: signature (deep, strict)" /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        report "Gatekeeper on the app in the DMG (spctl -t execute), not notarized" \
            /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
        report "syspolicy_check distribution on the app in the DMG, not notarized" \
            /usr/bin/syspolicy_check distribution "$app"
    else
        verify "the app in the DMG: notarization ticket (stapler validate)" /usr/bin/xcrun stapler validate "$app"
        verify "the app in the DMG: Gatekeeper accepts it (spctl -t execute)" /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
    fi
    check_assembled_app "$app" "$GATEKEEPER_CHECK"
    say "   ok  the app in the DMG: hippocampus-mind weak-links FoundationModels, every binary runs on macOS $MINIMUM_MACOS, version $RELEASE_VERSION, team $TEAM_ID"
    say "   ok  the app in the DMG: syspolicy_check $GATEKEEPER_CHECK accepts it"
    digest="$(clean_env python3 -B "$REPO_ROOT/scripts/product-source-digest.py" --repo-root "$REPO_ROOT")"
    verify "the app in the DMG was built from this commit and source" clean_env python3 -B \
        "$REPO_ROOT/scripts/build-provenance.py" verify --app "$app" \
        --expected-source-head "$RELEASE_HEAD" --expected-source-digest "$digest" --forbid-current-source
    /usr/bin/hdiutil detach "$mounted" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "$mounted" -force -quiet
    rmdir "$mounted" "$VERIFY_MOUNT_ROOT" 2>/dev/null || true
    VERIFY_MOUNT_ROOT=""
}

make_appcast() {
    local result
    [[ -x "$SIGN_UPDATE" ]] || stop "Sparkle's sign_update is not at $SIGN_UPDATE; the app's packages were not resolved."
    # One build, one appcast: never merge into a feed left by an earlier run.
    if [[ -e "$APPCAST" ]]; then mv -f "$APPCAST" "$LOG_DIR/appcast.previous-run.xml"; fi
    stage "appcast: Sparkle-sign the DMG, write appcast.xml from the CHANGELOG, sign the feed" appcast \
        SPARKLE_SIGN_UPDATE="$SIGN_UPDATE" "$REPO_ROOT/scripts/sparkle-publish.sh" \
        --dmg "$DMG" --private-key "$SPARKLE_KEY" --changelog-notes \
        --release-tag "$RELEASE_TAG" --dist "$DIST_DIR" --appcast "$APPCAST" --no-confirm
    result="$(release_identity_staged 2>&1)" || stop "appcast.xml failed the release identity gate: $result"
    say "   $result"
}

publish_ready_files() {
    local sha="$1"
    # Optional third asset: the Terminal installer, which fetches this DMG and
    # its checksum from the release and checks both before it installs.
    if [[ -f "$REPO_ROOT/scripts/install.sh" ]]; then
        install -m 0755 "$REPO_ROOT/scripts/install.sh" "$DIST_DIR/install.sh"
    fi
    if [[ -n "$NOTES_FILE" ]]; then
        sed "s/{{SHA256}}/$sha/g" "$NOTES_FILE" >"$DIST_DIR/release-notes.md"
        grep -q "$sha" "$DIST_DIR/release-notes.md" || stop "The notes file has no {{SHA256}} placeholder."
    fi
}

# --- Main ---

cd "$REPO_ROOT"
preflight
if (( FAILURES > 0 )); then
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        say ""
        say "Preflight: $FAILURES problem(s). Fix them, then run: scripts/release-0.3.0.sh"
        exit 1
    fi
    stop "Preflight found $FAILURES problem(s) above. Nothing was changed."
fi
if [[ "$CHECK_ONLY" -eq 1 ]]; then
    say ""
    if [[ "$DRY_RUN" -eq 1 ]]; then
        say "Preflight passed. For the dry run, run: scripts/release-0.3.0.sh --dry-run"
    else
        say "Preflight passed. To release, run: scripts/release-0.3.0.sh"
    fi
    exit 0
fi

mkdir -p "$LOG_DIR" "$DIST_DIR"
say ""
if [[ "$DRY_RUN" -eq 1 ]]; then
    say "=== Hippocampus $RELEASE_VERSION release DRY RUN, $(date '+%Y-%m-%d %H:%M') ==="
    say "    Signed here; not notarized, stamped, committed or opened. Never upload it."
else
    say "=== Hippocampus $RELEASE_VERSION release, $(date '+%Y-%m-%d %H:%M') ==="
fi
provision_installer_python
rebuild_ocr_if_stale
if [[ "$DRY_RUN" -eq 1 ]]; then
    say "== docs/STATUS.md not stamped and nothing committed (dry run)"
else
    stamp_status
fi
RELEASE_HEAD="$(head_sha)"
build_binaries
assemble_app
build_dmg
verify_release

SHA256="$(awk '{ print $1; exit }' "$DMG.sha256")"
[[ "$SHA256" == "$(/usr/bin/shasum -a 256 "$DMG" | awk '{ print $1 }')" ]] || stop "The checksum file does not match the DMG."
publish_ready_files "$SHA256"
make_appcast

UPLOADS=("$DMG" "$DMG.sha256" "$STABLE_DMG" "$STABLE_DMG.sha256" "$APPCAST")
if [[ -f "$DIST_DIR/install.sh" ]]; then UPLOADS+=("$DIST_DIR/install.sh"); fi

mb() { awk -v bytes="$1" 'BEGIN { printf "%.1f", bytes / 1048576 }'; }
DMG_BYTES="$(stat -f%z "$DMG")"
APP_BYTES="$(find "$APP" -type f -exec stat -f%z {} + | awk '{ total += $1 } END { print total }')"
BINARY_BYTES="$(stat -f%z "$APP"/Contents/MacOS/* | awk '{ total += $1 } END { print total }')"
DMG_FORMAT="$(/usr/bin/hdiutil imageinfo -format "$DMG" 2>/dev/null || echo unknown)"

if [[ "$DRY_RUN" -eq 1 ]]; then
    say ""
    say "=== Hippocampus $RELEASE_VERSION DRY RUN: built and signed here, and verified ==="
    say "  DMG:      $DMG"
    say "  Sizes:    DMG $(mb "$DMG_BYTES") MB ($DMG_BYTES bytes, $DMG_FORMAT); app $(mb "$APP_BYTES") MB, of which its binaries $(mb "$BINARY_BYTES") MB"
    say "  Symbols:  $SYMBOLS_DIR"
    say "  Commit:   $RELEASE_HEAD ($(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached))"
    say "  Gatekeeper on this build, which is not notarized:"
    for line in ${REPORTS[@]+"${REPORTS[@]}"}; do say "            $line"; done
    say ""
    say "DRY RUN: nothing was notarized, stamped, committed, pushed, tagged or uploaded,"
    say "and the app was never opened. Do not upload anything from $OUT_DIR."
    exit 0
fi

say ""
say "=== Hippocampus $RELEASE_VERSION is built, signed, notarized and verified ==="
say "  Sizes:    DMG $(mb "$DMG_BYTES") MB ($DMG_FORMAT); app $(mb "$APP_BYTES") MB, of which its binaries $(mb "$BINARY_BYTES") MB"
say "  DMG:      $DMG ($(du -h "$DMG" | awk '{ print $1 }'))"
say "  SHA-256:  $SHA256"
say "  Commit:   $RELEASE_HEAD ($RELEASE_BRANCH; STATUS baseline $(status_baseline))"
say "  Upload, all to the $RELEASE_TAG release:"
for upload in "${UPLOADS[@]}"; do say "            $upload"; done
if [[ -n "$NOTES_FILE" ]]; then
    say "  Notes:    $DIST_DIR/release-notes.md"
fi
say ""
say "  Installed copies check $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST"),"
say "  which is this appcast.xml once the release is published as Latest. A draft or"
say "  a prerelease changes nothing for them. After pushing $RELEASE_BRANCH:"
say "    gh release create $RELEASE_TAG --draft --target $RELEASE_HEAD --title \"Hippocampus $RELEASE_VERSION\" \\"
if [[ -n "$NOTES_FILE" ]]; then
    say "      --notes-file \"$DIST_DIR/release-notes.md\" \\"
fi
say "      $(printf '"%s" ' "${UPLOADS[@]}")"
say "    gh release edit $RELEASE_TAG --draft=false --latest   # once the draft is inspected"
say "Nothing was pushed, tagged or uploaded."
