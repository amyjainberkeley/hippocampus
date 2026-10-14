#!/usr/bin/env bash
set -euo pipefail

# release-0.3.0.sh — Build, sign, notarize and verify Hippocampus 0.3.0 on this Mac.
#
#   scripts/release-0.3.0.sh --check   # every quick gate; builds and commits nothing
#   scripts/release-0.3.0.sh           # the release
#
# The release, in order, stopping at the first failure:
#   1. Preflight: branch, clean tree, release identity, CHANGELOG, Cargo.lock,
#      models, OCR worker, toolchain, Developer ID, notary profile, installer
#      assets, installer Python, power and disk. Nothing changes if it fails.
#   2. Set up the installer's Python (two hashed wheels from PyPI) if needed.
#   3. Rebuild the offline OCR worker if it no longer matches tools/ocr.
#   4. Stamp docs/STATUS.md with HEAD and commit "docs(status): release baseline".
#   5. Build release binaries: cargo, then the five Swift packages, including
#      hippocampus-mind.
#   6. Assemble and sign Hippocampus.app (apps/hippocampus/Resources/build-app.sh).
#   7. Make, sign, notarize and staple the DMG (scripts/build-installer.sh).
#   8. Verify the DMG and the app inside it; print the DMG path and SHA-256.
#
# Steps 6 and 7 each open the new app for 20 seconds under a throwaway home
# (the launch check), so its setup window shows on screen twice. Steps 2, 6
# and 7 use the network (PyPI, Apple's timestamp and notary services).
# Nothing is pushed, tagged or uploaded.
#
# release-models.json is not read here: it names the model archive the
# tag-triggered CI release downloads. This build bundles models/ from this Mac.
#
# Options:
#   --check           Run the preflight only.
#   --out DIR         Where the DMG, logs and installer Python go
#                     (default: ~/Hippocampus-release-candidates/0.3.0).
#   --notes FILE      Release notes containing {{SHA256}}; a filled copy is
#                     written beside the DMG as release-notes.md.
#   --jobs N          Parallel build jobs (default: 4).
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

CHECK_ONLY=0
ALLOW_LOW_DISK=0
JOBS=4
OUT_DIR="$HOME/Hippocampus-release-candidates/$RELEASE_VERSION"
NOTES_FILE=""

usage() {
    sed -n '4,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --out) [[ $# -ge 2 ]] || { usage; exit 2; }; OUT_DIR="$2"; shift 2 ;;
        --notes) [[ $# -ge 2 ]] || { usage; exit 2; }; NOTES_FILE="$2"; shift 2 ;;
        --jobs) [[ $# -ge 2 ]] || { usage; exit 2; }; JOBS="$2"; shift 2 ;;
        --allow-low-disk) ALLOW_LOW_DISK=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs needs a positive number" >&2; exit 2; }
[[ "$OUT_DIR" == /* ]] || OUT_DIR="$PWD/$OUT_DIR"
if [[ -n "$NOTES_FILE" ]]; then
    [[ "$NOTES_FILE" == /* ]] || NOTES_FILE="$PWD/$NOTES_FILE"
    [[ -f "$NOTES_FILE" ]] || { echo "No notes file at $NOTES_FILE" >&2; exit 2; }
fi

LOG_DIR="$OUT_DIR/logs"
DIST_DIR="$OUT_DIR/installer"
INSTALLER_VENV="$OUT_DIR/installer-python"
DMG="$DIST_DIR/Hippocampus-$RELEASE_VERSION.dmg"
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

status_baseline() {
    [[ -f "$STATUS_FILE" ]] || return 0
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

macho_minos() {
    { /usr/bin/otool -l "$1" 2>/dev/null || true; } \
        | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" && !done { print $2; done = 1 }'
}

# The load command that brings in FoundationModels, if any.
foundation_models_link() {
    { /usr/bin/otool -l "$1" 2>/dev/null || true; } | awk '
        $1 == "cmd" { cmd = $2 }
        $1 == "name" && $2 ~ /FoundationModels/ && !done { print cmd; done = 1 }'
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

preflight() {
    local branch changes count result baseline sdk tool missing identities power percent free need

    say "=== Hippocampus $RELEASE_VERSION release preflight ==="
    say "Repository: $REPO_ROOT"
    say "Output:     $OUT_DIR"

    branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$branch" == "$RELEASE_BRANCH" ]]; then
        ok "branch $RELEASE_BRANCH at $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
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
    if [[ -n "$baseline" ]]; then
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

    if clean_env xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        ok "notary keychain profile '$NOTARY_PROFILE' works"
    else
        fail "notary keychain profile '$NOTARY_PROFILE' does not work (or Apple's service is unreachable)"
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
    info "release-models.json (0.2.0) is read only by the tag-triggered CI release; a $RELEASE_TAG tag makes that job stop before it builds anything"
    info "the launch check opens the new app for 20 s, twice, under a throwaway home"
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
    local baseline="$1" attempt
    for attempt in 1 2 3 4 5 6; do
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

    for pkg in \
        apps/hippocampus/.build/release/Hippocampus \
        adapters/macos/MCICaptureHelper/.build/release/mci-capture-helper \
        target/release/mci-agent \
        target/release/hippocampus-native-host \
        apps/recall-ui/.build/release/recall-ui \
        apps/onboarding/.build/release/onboarding \
        apps/mind/.build/release/hippocampus-mind; do
        [[ -x "$REPO_ROOT/$pkg" ]] || stop "The build did not produce $pkg."
    done
    require_clean_tree "After the build."
}

check_assembled_app() {
    local app="$1" binary minos link version team
    [[ -x "$app/Contents/MacOS/hippocampus-mind" ]] \
        || stop "hippocampus-mind is not in $app; answers would need it."
    link="$(foundation_models_link "$app/Contents/MacOS/hippocampus-mind")"
    [[ "$link" == "LC_LOAD_WEAK_DYLIB" ]] \
        || stop "hippocampus-mind links FoundationModels as ${link:-nothing}, not weakly; it would not start on macOS 14 or 15, or could not use Apple Intelligence."
    for binary in "$app"/Contents/MacOS/*; do
        minos="$(macho_minos "$binary")"
        [[ -z "$minos" ]] || version_at_most "$minos" "$MINIMUM_MACOS" \
            || stop "$(basename "$binary") needs macOS $minos; Hippocampus promises macOS $MINIMUM_MACOS."
    done
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$version" == "$RELEASE_VERSION" ]] || stop "The app says version ${version:-none}, not $RELEASE_VERSION."
    if /usr/libexec/PlistBuddy -c 'Print :MCIDevelopmentFileKeyEnabled' "$app/Contents/Info.plist" >/dev/null 2>&1; then
        stop "The app turns on the development file key. Only an ad-hoc test build may do that."
    fi
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
        || stop "codesign --verify --deep --strict failed for $app."
    team="$(/usr/bin/codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$team" == "$TEAM_ID" ]] || stop "The app is signed by team ${team:-none}, not $TEAM_ID."
}

assemble_app() {
    require_disk "assemble Hippocampus.app"
    [[ "$(head_sha)" == "$RELEASE_HEAD" ]] || stop "HEAD moved during the build. Run this script again."
    stage "assemble and sign Hippocampus.app (includes the 20 s launch check)" assemble \
        DEVELOPER_ID="$DEVELOPER_ID" "$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
    check_assembled_app "$APP"
    say "   hippocampus-mind included (FoundationModels weak), every binary runs on macOS $MINIMUM_MACOS, signed by $TEAM_ID"
}

build_dmg() {
    require_disk "make the DMG"
    [[ "$(head_sha)" == "$RELEASE_HEAD" ]] || stop "HEAD moved during the build. Run this script again."
    require_clean_tree "Before the DMG."
    mkdir -p "$DIST_DIR"
    stage "DMG: sign, notarize and staple the app and the DMG (launch check, then Apple's notary service)" installer \
        DEVELOPER_ID="$DEVELOPER_ID" INSTALLER_PYTHON="$INSTALLER_VENV/bin/python" \
        "$REPO_ROOT/scripts/build-installer.sh" --skip-build --dist "$DIST_DIR"
    [[ -f "$DMG" && -f "$DMG.sha256" ]] || stop "build-installer.sh finished without $DMG and its .sha256."
}

VERIFY_LOG=""
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
    verify "hdiutil verify" /usr/bin/hdiutil verify "$DMG"
    verify "DMG signature" /usr/bin/codesign --verify --strict --verbose=2 "$DMG"
    verify "DMG notarization ticket (stapler validate)" /usr/bin/xcrun stapler validate "$DMG"
    verify "Gatekeeper accepts the DMG (spctl -t open)" \
        /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    verify "the assembled app's signature (deep, strict)" /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

    VERIFY_MOUNT_ROOT="$(mktemp -d "$BUILD_TMPDIR/hippocampus-release-verify.XXXXXX")"
    mounted="$VERIFY_MOUNT_ROOT/volume"
    mkdir "$mounted"
    verify "the DMG opens read-only" /usr/bin/hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -noverify -mountpoint "$mounted"
    app="$mounted/Hippocampus.app"
    verify "the DMG holds Hippocampus.app and an Applications link" /bin/sh -c "test -d \"$app\" && test -L \"$mounted/Applications\""
    verify "the app in the DMG: signature (deep, strict)" /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
    verify "the app in the DMG: notarization ticket (stapler validate)" /usr/bin/xcrun stapler validate "$app"
    verify "the app in the DMG: Gatekeeper accepts it (spctl -t execute)" /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
    check_assembled_app "$app"
    say "   ok  the app in the DMG: version $RELEASE_VERSION, hippocampus-mind included, macOS $MINIMUM_MACOS"
    digest="$(clean_env python3 -B "$REPO_ROOT/scripts/product-source-digest.py" --repo-root "$REPO_ROOT")"
    verify "the app in the DMG was built from this commit and source" clean_env python3 -B \
        "$REPO_ROOT/scripts/build-provenance.py" verify --app "$app" \
        --expected-source-head "$RELEASE_HEAD" --expected-source-digest "$digest" --forbid-current-source
    /usr/bin/hdiutil detach "$mounted" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "$mounted" -force -quiet
    rmdir "$mounted" "$VERIFY_MOUNT_ROOT" 2>/dev/null || true
    VERIFY_MOUNT_ROOT=""
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
    say "Preflight passed. To release, run: scripts/release-0.3.0.sh"
    exit 0
fi

mkdir -p "$LOG_DIR" "$DIST_DIR"
say ""
say "=== Hippocampus $RELEASE_VERSION release, $(date '+%Y-%m-%d %H:%M') ==="
provision_installer_python
rebuild_ocr_if_stale
stamp_status
RELEASE_HEAD="$(head_sha)"
build_binaries
assemble_app
build_dmg
verify_release

SHA256="$(awk '{ print $1; exit }' "$DMG.sha256")"
[[ "$SHA256" == "$(/usr/bin/shasum -a 256 "$DMG" | awk '{ print $1 }')" ]] || stop "The checksum file does not match the DMG."
publish_ready_files "$SHA256"

say ""
say "=== Hippocampus $RELEASE_VERSION is built, signed, notarized and verified ==="
say "  DMG:      $DMG ($(du -h "$DMG" | awk '{ print $1 }'))"
say "  SHA-256:  $SHA256"
say "  Commit:   $RELEASE_HEAD ($RELEASE_BRANCH; STATUS baseline $(status_baseline))"
say "  Upload:   $DMG"
say "            $DMG.sha256"
if [[ -f "$DIST_DIR/install.sh" ]]; then
    say "            $DIST_DIR/install.sh (optional, the Terminal installer)"
fi
if [[ -n "$NOTES_FILE" ]]; then
    say "  Notes:    $DIST_DIR/release-notes.md"
fi
say "Nothing was pushed, tagged or uploaded."
