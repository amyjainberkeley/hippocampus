#!/usr/bin/env bash
# e2e-full.sh — one full end-to-end test of Hippocampus, the way a new user
# gets it, in a throwaway home.
#
#   (a) Installer: the app built as build-app.sh's development mode builds it,
#       and the DMG build-installer.sh makes from it, mounted read-only and
#       checked: signatures, layout, architectures, Info.plist usage strings.
#   (b) First launch: the built app (never /Applications) under the throwaway
#       HOME through the existing launch gate (verify-app-launches.sh). Setup
#       appears and stays up, and nothing is captured before consent.
#   (c) Memory: made-up windows through the capture helper's pipeline in
#       fixture mode (SyntheticCaptureFeed: the production reader, secret
#       checks and sealed screenshots), into the bundled mci-agent exactly as
#       the app runs it, then the window's own reads (WindowReadsProbe over
#       mci-brain-ffi), search and Ask (CLI and MCP), the handoff packet
#       (e2e-handoff.sh --synthetic), Resume's plan, and secret redaction.
#   (d) Forgetting and retention: one moment, a time range, and a retention
#       window, checked in the memory, the screenshots and what was derived.
#   (e) Uninstall: Quit leaves nothing running, AI tools disconnected, and the
#       cask's zap list removed; anything left in the home is listed.
#
# Then scripts/audit-storage-security.sh audits the throwaway home.
#
# Every check prints one line: PASS, FAIL, SKIP or PERSON (needs a person),
# with its reason. The summary counts them; the exit status is 1 when any
# check failed.
#
# Safety. Everything runs under one throwaway root (/tmp/hippo-e2e.XXXXXX):
# its own HOME (and CFFIXED_USER_HOME), TMPDIR and a development file key.
# The Keychain is never read: every program that could fall back to it is
# given the development key gate and a Keychain service name that does not
# exist. Nothing opens /Applications/Hippocampus.app, changes privacy
# permissions, touches the real ~/.claude or ~/.codex, or reads the screen.
# The app is launched from the built bundle only, for (b) and for Quit.
#
# Usage: scripts/e2e-full.sh [OPTIONS]
#   --app PATH            use this built Hippocampus.app (default: build it)
#   --dmg PATH            use this DMG for (a) (default: build it from the app)
#   --reference-dmg PATH  also inspect a release-signed DMG read-only for (a)
#   --headless            no GUI: skip (a) and (b) and Quit; use the debug
#                         binaries and the Vision reader when no --app is given
#   --ocr auto|paddle|vision  which reader the fixture uses (default auto:
#                         the app's bundled PP-OCR worker when there is one)
#   --allow-ocr-network   run the PP-OCR worker without the test's own rules.
#                         It always runs inside the product's sandbox, which
#                         denies every network operation and name lookups
#                         (the bundled ONNX Runtime once uploaded telemetry to
#                         Microsoft: E2E-REPORT, finding 1); by default the
#                         test also closes the real ~/Library to it. With this
#                         flag only the product's own sandbox applies, which
#                         checks that it is enough on its own
#   --no-audit            do not run audit-storage-security.sh
#   --keep                keep the throwaway root (default: only on failure)
#   --evidence DIR        copy the results, logs and audit into DIR
#   -h, --help            this text
#
# Steps that truly need a person (Screen Recording and Accessibility granted
# to a build, Shift twice on a real keyboard, a notarized first open) are
# printed as PERSON lines; reports/e2e/HUMAN-CHECKLIST.md walks through them.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP=""
DMG=""
REFERENCE_DMG=""
HEADLESS=0
OCR_CHOICE="auto"
OCR_SANDBOX=1
AUDIT=1
KEEP=0
EVIDENCE_DIR=""

usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="${2:-}"; shift 2 ;;
        --dmg) DMG="${2:-}"; shift 2 ;;
        --reference-dmg) REFERENCE_DMG="${2:-}"; shift 2 ;;
        --headless) HEADLESS=1; shift ;;
        --ocr) OCR_CHOICE="${2:-}"; shift 2 ;;
        --allow-ocr-network) OCR_SANDBOX=0; shift ;;
        --no-audit) AUDIT=0; shift ;;
        --keep) KEEP=1; shift ;;
        --evidence) EVIDENCE_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
case "$OCR_CHOICE" in auto|paddle|vision) ;; *) echo "--ocr must be auto, paddle or vision" >&2; exit 2 ;; esac

# ---- The throwaway root ------------------------------------------------------
# Short, so the agent's AF_UNIX socket path stays under Darwin's 104 bytes.
RUN_ROOT="$(mktemp -d /tmp/hippo-e2e.XXXXXX)"
RUN_ROOT="$(cd "$RUN_ROOT" && pwd -P)"
chmod 700 "$RUN_ROOT"
E2E_HOME="$RUN_ROOT/home"
E2E_TMP="$RUN_ROOT/tmp"
H="$RUN_ROOT/harness"           # the test's own evidence, never product state
MNT="$RUN_ROOT/mnt"
mkdir -p "$E2E_HOME" "$E2E_TMP" "$H" "$MNT"
chmod 700 "$E2E_HOME" "$E2E_TMP" "$H"
SUPPORT="$E2E_HOME/Library/Application Support/MCI"
DB="$SUPPORT/mci.sqlite"
KEY_FILE="$SUPPORT/dev.key"
RESULTS="$H/results.tsv"
: > "$RESULTS"
START_EPOCH="$(date +%s)"
MOUNTED=""
SAMPLER_PID=""

STATUS_PASS=0
STATUS_FAIL=0
STATUS_SKIP=0
STATUS_PERSON=0

# ---- Reporting ---------------------------------------------------------------
record() {
    local status="$1" step="$2" message="$3"
    printf '%-6s %-5s %s\n' "$status" "$step" "$message"
    printf '%s\t%s\t%s\n' "$status" "$step" "$message" >> "$RESULTS"
    case "$status" in
        PASS) STATUS_PASS=$((STATUS_PASS + 1)) ;;
        FAIL) STATUS_FAIL=$((STATUS_FAIL + 1)) ;;
        SKIP) STATUS_SKIP=$((STATUS_SKIP + 1)) ;;
        PERSON) STATUS_PERSON=$((STATUS_PERSON + 1)) ;;
    esac
}
pass() { record PASS "$1" "$2"; }
fail() { record FAIL "$1" "$2"; }
skip() { record SKIP "$1" "$2"; }
person() { record PERSON "$1" "$2"; }
section() { printf '\n== %s\n' "$1"; }
# run_with_timeout SECONDS COMMAND...: macOS has no timeout(1).
run_with_timeout() {
    local seconds="$1" pid waited=0
    shift
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= seconds * 10 )); then
            kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    wait "$pid"
}

cleanup() {
    local status=$?
    set +e
    [[ -z "$MOUNTED" ]] || hdiutil detach "$MOUNTED" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNTED" -force -quiet >/dev/null 2>&1
    rm -f "$H/.sampling"
    [[ -z "$SAMPLER_PID" ]] || wait "$SAMPLER_PID" 2>/dev/null
    # Only processes this run started, found by parentage.
    local pid
    for pid in $(pgrep -P $$ 2>/dev/null); do kill -TERM "$pid" 2>/dev/null; done
    if [[ -n "$EVIDENCE_DIR" ]]; then
        # The WAL copies are ciphertext the audit already judged; list them.
        mkdir -p "$EVIDENCE_DIR"
        (cd "$H" && find . -mindepth 1 -maxdepth 1 ! -name wal-snapshots ! -name .sampling -exec cp -R {} "$EVIDENCE_DIR/" \;) 2>/dev/null
        ls -l "$H/wal-snapshots" > "$EVIDENCE_DIR/wal-snapshots.txt" 2>/dev/null
    fi
    if (( KEEP == 1 || STATUS_FAIL > 0 )); then
        printf '\nThrowaway root kept at %s\n' "$RUN_ROOT"
    else
        rm -rf "$RUN_ROOT"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- The product environment ------------------------------------------------
# Every product program runs with this environment and nothing else.
product_env() {
    env -i \
        HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" TMPDIR="$E2E_TMP/" \
        USER="${USER:-e2e}" LANG="${LANG:-en_US.UTF-8}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        MCI_DEVELOPMENT_FILE_KEY=1 MCI_DB_KEY_FILE="$KEY_FILE" MCI_DB_PATH="$DB" \
        MCI_DB_KEYCHAIN_SERVICE="ai.hippocampus.e2e.absent.$$" MCI_DB_KEYCHAIN_ACCOUNT="absent" \
        MCI_CLAUDE_BINARY=/usr/bin/true MCI_CODEX_BINARY=/usr/bin/true CODEX_HOME="$E2E_HOME/.codex" \
        "${E2E_EXTRA_ENV[@]+"${E2E_EXTRA_ENV[@]}"}" \
        "$@"
}
E2E_EXTRA_ENV=()

json_field() { python3 -c 'import json,sys; v=json.load(sys.stdin); print(eval(sys.argv[1], {"v": v}))' "$1"; }

printf 'Hippocampus full end-to-end test — %s — %s\n' \
    "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Throwaway root: %s\n' "$RUN_ROOT"

# A security(1) stand-in that finds no signing identity, so the build and
# installer scripts take their development path and never list the Keychain.
mkdir -p "$H/no-identity-bin"
printf '#!/bin/sh\necho "     0 valid identities found"\nexit 0\n' > "$H/no-identity-bin/security"
chmod +x "$H/no-identity-bin/security"

# ---- Network and file sampler (runs the whole time) --------------------------
: > "$H/.sampling"
python3 "$SCRIPT_DIR/lib/e2e_sampler.py" --root-pid $$ --run-root "$RUN_ROOT" \
    --out-dir "$H/sampler" --stop-file "$H/.sampling" --allow "$REPO_ROOT" \
    ${APP:+--allow "$APP"} > "$H/sampler.stdout" 2>&1 &
SAMPLER_PID=$!

# ---- Tools ----------------------------------------------------------------------
# Builds run from the checkout, where rust-toolchain.toml pins the compiler.
cd "$REPO_ROOT" || exit 1
section "Build: Rust engine and the fixture tools"
FEED="$REPO_ROOT/adapters/macos/MCICaptureHelper/.build/debug/SyntheticCaptureFeed"
PROBE="$REPO_ROOT/apps/recall-ui/.build/debug/WindowReadsProbe"
KEYFRAME_TOOL="$REPO_ROOT/adapters/macos/MCIKeyframeCodec/.build/debug/KeyframeFixtureBuilder"
BRAIN_CLI="$REPO_ROOT/target/debug/mci-brain"
build_tools() {
    cargo build --quiet --jobs 2 -p mci-agent --bins --manifest-path "$REPO_ROOT/Cargo.toml" \
        && "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/adapters/macos/MCIKeyframeCodec" --product KeyframeFixtureBuilder --jobs 2 \
        && "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/adapters/macos/MCICaptureHelper" --product SyntheticCaptureFeed --jobs 2 \
        && "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/apps/recall-ui" --product WindowReadsProbe --jobs 2
}
if build_tools > "$H/build-tools.log" 2>&1; then
    pass build "mci-agent, mci-brain, SyntheticCaptureFeed, WindowReadsProbe and KeyframeFixtureBuilder built"
else
    fail build "tool build failed: $(tail -n 1 "$H/build-tools.log")"
    exit 1
fi

# ---- (a) Installer ------------------------------------------------------------
section "(a) Installer"
if (( HEADLESS == 1 )) && [[ -z "$APP" ]]; then
    skip a "headless run without --app: no app bundle or DMG is built"
else
    if [[ -z "$APP" ]]; then
        # The app the way build-app.sh's development mode assembles it, from
        # debug builds, ad-hoc signed with the development file key. Its own
        # launch gates (verify-app-launches.sh, verify-parent-lifetime.sh)
        # run as part of the build under their own throwaway homes.
        if {
            "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/apps/hippocampus" --jobs 2 \
            && "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/adapters/macos/MCICaptureHelper" --jobs 2 \
            && "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/apps/recall-ui" --jobs 2 \
            && "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/apps/onboarding" --jobs 2 \
            && { "$SCRIPT_DIR/swift-package.sh" build --package-path "$REPO_ROOT/apps/mind" --jobs 2 || true; } \
            && cargo build --jobs 2 --manifest-path "$REPO_ROOT/Cargo.toml" -p mci-agent --bins -p hippocampus-native-host \
            && PATH="$H/no-identity-bin:$PATH" DEVELOPER_ID="" "$REPO_ROOT/apps/hippocampus/Resources/build-app.sh" --debug --development-ad-hoc
        } > "$H/build-app.log" 2>&1; then
            APP="$REPO_ROOT/apps/hippocampus/dist/Hippocampus.app"
            pass a1 "app bundle assembled by build-app.sh --debug --development-ad-hoc (its launch and parent-lifetime gates passed)"
        else
            fail a1 "build-app.sh failed: $(grep -E 'FATAL|ERROR|error:' "$H/build-app.log" | tail -n 1)"
        fi
    else
        pass a1 "using the given app bundle $APP"
    fi
fi
if [[ -n "$APP" ]]; then
    APP="$(cd "$APP" && pwd -P)"
fi

inspect_dmg() {
    # $1 step prefix, $2 DMG, $3 kind (development|release)
    local id="$1" image="$2" kind="$3" mount_point="$MNT/$1" app
    mkdir -p "$mount_point"
    if ! hdiutil attach -readonly -nobrowse -noautoopen -noverify -mountpoint "$mount_point" "$image" > "$H/$id-attach.log" 2>&1; then
        fail "$id.mount" "could not mount $image read-only: $(tail -n 1 "$H/$id-attach.log")"
        return
    fi
    MOUNTED="$mount_point"
    local mounts
    mounts="$(mount)"
    if grep -F " on $mount_point " <<< "$mounts" | grep -q "read-only"; then
        pass "$id.mount" "$(basename "$image") mounted read-only at a private mount point (no Finder, no auto-open)"
    else
        fail "$id.mount" "the volume is not mounted read-only"
    fi
    # Layout: the app, the Applications drop target, the license, the window.
    local expected=(".VolumeIcon.icns" ".background" "Applications" "Hippocampus.app" "Legal")
    local actual
    actual="$(cd "$mount_point" && ls -A | grep -v -E '^\.(DS_Store|fseventsd|Trashes|TemporaryItems)$' | sort | tr '\n' ' ')"
    if [[ "$actual" == "$(printf '%s\n' "${expected[@]}" | sort | tr '\n' ' ')" ]] \
        && [[ "$(readlink "$mount_point/Applications")" == "/Applications" ]] \
        && [[ -f "$mount_point/Legal/License.rtf" && -f "$mount_point/.background/background.png" ]]; then
        pass "$id.layout" "layout: Hippocampus.app, Applications -> /Applications, Legal/License.rtf, background, volume icon; nothing else"
    else
        fail "$id.layout" "unexpected layout: [$actual] Applications -> $(readlink "$mount_point/Applications" 2>/dev/null)"
    fi
    app="$mount_point/Hippocampus.app"
    # Signatures.
    if codesign --verify --deep --strict "$app" > "$H/$id-codesign.log" 2>&1; then
        # Read the signature once, then match it: a grep -q that stops early
        # would cut codesign's output, and pipefail would call that a mismatch.
        local signature authority team
        signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
        printf '%s\n' "$signature" >> "$H/$id-codesign.log"
        authority="$(sed -n 's/^Authority=//p' <<< "$signature" | head -n 1)"
        team="$(sed -n 's/^TeamIdentifier=//p' <<< "$signature")"
        if grep -q '^Signature=adhoc' <<< "$signature"; then
            pass "$id.sign" "codesign --verify --deep --strict passes; signature is ad-hoc (development build: no Team ID, no hardened runtime)"
        else
            pass "$id.sign" "codesign --verify --deep --strict passes; signed by ${authority:-?} (Team ID ${team:-?})"
        fi
    else
        fail "$id.sign" "codesign verification failed: $(tail -n 1 "$H/$id-codesign.log")"
    fi
    local unsigned=() binary
    while IFS= read -r binary; do
        codesign --verify --strict "$binary" >/dev/null 2>&1 || unsigned+=("${binary#"$app/"}")
    done < <(find "$app/Contents/MacOS" -type f -perm -0100)
    if (( ${#unsigned[@]} == 0 )); then
        pass "$id.sign-each" "every executable in Contents/MacOS verifies on its own"
    else
        fail "$id.sign-each" "executables that do not verify: ${unsigned[*]}"
    fi
    if [[ "$kind" == "release" ]]; then
        if spctl --assess --type execute -vv "$app" > "$H/$id-spctl.log" 2>&1; then
            pass "$id.gatekeeper" "Gatekeeper accepts the app (spctl --assess): $(grep '^source=' "$H/$id-spctl.log")"
        elif grep -q 'Unnotarized Developer ID' "$H/$id-spctl.log"; then
            person "$id.gatekeeper" "Gatekeeper: 'Unnotarized Developer ID' — the dry run never notarizes; notarizing and stapling need the owner's Developer ID and notary profile (scripts/release-0.3.0.sh)"
        else
            fail "$id.gatekeeper" "Gatekeeper rejects the app: $(tail -n 1 "$H/$id-spctl.log")"
        fi
        if xcrun stapler validate "$image" > "$H/$id-stapler.log" 2>&1; then
            pass "$id.staple" "the DMG carries a stapled notarization ticket"
        else
            person "$id.staple" "no stapled notarization ticket on the DMG (a dry run is never notarized; the real release staples it)"
        fi
        local runtime
        runtime="$(codesign -dv --verbose=2 "$app/Contents/MacOS/MCICaptureHelper" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)' | head -n 1)"
        if [[ "$runtime" == *runtime* ]]; then
            pass "$id.runtime" "the capture helper has the hardened runtime ($runtime)"
        else
            fail "$id.runtime" "the capture helper lacks the hardened runtime ($runtime)"
        fi
    else
        spctl --assess --type execute -vv "$app" > "$H/$id-spctl.log" 2>&1
        person "$id.gatekeeper" "Gatekeeper and notarization apply to the signed release only; this ad-hoc build is rejected by design ($(grep -E '^source=|rejected' "$H/$id-spctl.log" | tail -n 1)). Opening the notarized DMG on a fresh account needs a person (HUMAN-CHECKLIST step 1)."
    fi
    # Telemetry endpoints compiled into anything the app ships. ONNX Runtime
    # 1.30's client in the OCR worker passes only when it is switched off
    # three ways (the worker's own two switches, in its frozen script and
    # source, and the launch's) and the programs that start the worker carry
    # the no-network sandbox; the audit's net.binary also checks the running
    # worker. Any other endpoint fails (storage_audit.py --telemetry-bundle).
    local telemetry
    if telemetry="$(python3 "$SCRIPT_DIR/lib/storage_audit.py" --repo "$REPO_ROOT" --telemetry-bundle "$app" 2>&1)"; then
        pass "$id.telemetry" "$telemetry"
    else
        fail "$id.telemetry" "$telemetry"
    fi
    # Architectures.
    local archs_report="$H/$id-architectures.txt" arm_only=1 any_x86=0 line
    : > "$archs_report"
    while IFS= read -r binary; do
        if file -b "$binary" | grep -q 'Mach-O'; then
            line="$(lipo -archs "$binary" 2>/dev/null)"
            printf '%s\t%s\n' "${binary#"$app/"}" "$line" >> "$archs_report"
            [[ "$line" == *x86_64* ]] && any_x86=1
            [[ "$line" == "arm64" || "$line" == "arm64e" ]] || arm_only=0
        fi
    done < <(find "$app/Contents" -type f \( -perm -0100 -o -name '*.dylib' -o -name '*.so' \) | head -n 400)
    local count own own_x86 universal
    count="$(wc -l < "$archs_report" | tr -d ' ')"
    own="$(grep -E '^Contents/MacOS/|^Contents/Resources/HippocampusOCR/hippocampus-ocr' "$archs_report")"
    own_x86="$(printf '%s\n' "$own" | grep -c x86_64)"
    universal="$(grep x86_64 "$archs_report" | cut -f1 | sed -E 's|^Contents/Frameworks/([^/]+)/.*|\1|' | sort -u | tr '\n' ' ')"
    if [[ -n "$own" && "$own_x86" == "0" ]] && ! printf '%s\n' "$own" | grep -qv $'\tarm64$'; then
        pass "$id.arch" "lipo: the app's $(printf '%s\n' "$own" | grep -c .) executables (Contents/MacOS and the OCR worker) are arm64 only, so Intel Macs are not supported: the app refuses to start on Intel (MciBootGuards.hostIsAppleSilicon) and the cask requires arm64.${universal:+ Universal parts come from ${universal}(prebuilt).} $count Mach-O files checked; see $id-architectures.txt"
    else
        fail "$id.arch" "lipo: the app's own executables are not uniformly arm64: $(printf '%s\n' "$own" | grep -v $'\tarm64$' | head -n 3 | tr '\n' ';')"
    fi
    # Info.plist and usage strings.
    local plist="$app/Contents/Info.plist" key value missing=()
    : > "$H/$id-usage-strings.txt"
    for key in NSScreenCaptureUsageDescription NSAccessibilityUsageDescription NSAppleEventsUsageDescription \
        NSCalendarsUsageDescription NSCalendarsFullAccessUsageDescription NSContactsUsageDescription \
        NSAppleMusicUsageDescription; do
        value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"
        if [[ -z "$value" ]]; then
            missing+=("$key")
        else
            printf '%s: %s\n' "$key" "$value" >> "$H/$id-usage-strings.txt"
        fi
    done
    local core_missing=()
    for key in ${missing[@]+"${missing[@]}"}; do
        case "$key" in NSScreenCaptureUsageDescription|NSAccessibilityUsageDescription|NSAppleEventsUsageDescription) core_missing+=("$key") ;; esac
    done
    if (( ${#missing[@]} == 0 )); then
        pass "$id.usage" "Info.plist has all 7 usage strings (Screen Recording, Accessibility, Automation, Calendars x2, Contacts, Media); text in $id-usage-strings.txt"
    elif [[ "$kind" == "release" && ${#core_missing[@]} -eq 0 ]]; then
        pass "$id.usage" "Info.plist has the Screen Recording, Accessibility and Automation usage strings; it lacks ${missing[*]}, which this branch added after that build"
    else
        fail "$id.usage" "Info.plist lacks: ${missing[*]}"
    fi
    local bundle_id version minimum ui_element feed dev_key
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)"
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
    minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null)"
    ui_element="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist" 2>/dev/null)"
    feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null)"
    dev_key="$(/usr/libexec/PlistBuddy -c 'Print :MCIDevelopmentFileKeyEnabled' "$plist" 2>/dev/null)"
    if [[ "$bundle_id" == "ai.hippocampus" && "$minimum" == "14.0" && "$ui_element" == "true" && "$feed" == https://github.com/* ]]; then
        pass "$id.plist" "Info.plist: $bundle_id $version, macOS $minimum or later, menu-bar only, update feed over https on github.com"
    else
        fail "$id.plist" "Info.plist: id=$bundle_id version=$version min=$minimum LSUIElement=$ui_element feed=$feed"
    fi
    if [[ "$kind" == "release" && "$dev_key" == "true" ]]; then
        fail "$id.devkey" "a release-signed app carries MCIDevelopmentFileKeyEnabled"
    elif [[ "$kind" == "release" ]]; then
        pass "$id.devkey" "the release-signed app has no development file-key capability"
    else
        pass "$id.devkey" "development build: MCIDevelopmentFileKeyEnabled=${dev_key:-absent} (file key, never the Keychain)"
    fi
    hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1
    MOUNTED=""
}

if [[ -n "$APP" ]] && (( HEADLESS == 0 )); then
    if [[ -z "$DMG" ]]; then
        INSTALLER_PYTHON_GUESS="${INSTALLER_PYTHON:-}"
        if [[ -z "$INSTALLER_PYTHON_GUESS" ]]; then
            for candidate in "$HOME"/Hippocampus-release-candidates/*/installer-python/bin/python; do
                [[ -x "$candidate" ]] && INSTALLER_PYTHON_GUESS="$candidate"
            done
        fi
        if [[ -z "$INSTALLER_PYTHON_GUESS" ]]; then
            fail a2 "no installer Python with ds-store and mac-alias (set INSTALLER_PYTHON; see scripts/installer-requirements.txt)"
        elif [[ "$APP" != "$REPO_ROOT/apps/hippocampus/dist/Hippocampus.app" ]]; then
            skip a2 "build-installer.sh packages apps/hippocampus/dist/Hippocampus.app only; pass --dmg for a given app"
        elif PATH="$H/no-identity-bin:$PATH" DEVELOPER_ID="" INSTALLER_PYTHON="$INSTALLER_PYTHON_GUESS" \
            "$SCRIPT_DIR/build-installer.sh" --skip-build --debug --development-ad-hoc --dist "$RUN_ROOT/dmg" \
            > "$H/build-installer.log" 2>&1; then
            DMG="$RUN_ROOT/dmg/Hippocampus-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist").dmg"
            pass a2 "DMG built by build-installer.sh --skip-build --debug --development-ad-hoc ($(du -h "$DMG" | awk '{print $1}'); its launch gate passed)"
        else
            fail a2 "build-installer.sh failed: $(grep -E 'FATAL|ERROR|error' "$H/build-installer.log" | tail -n 1)"
        fi
    else
        pass a2 "using the given DMG $DMG"
    fi
    if [[ -n "$DMG" && -f "$DMG" ]]; then
        inspect_dmg a3 "$DMG" development
    fi
    if [[ -n "$REFERENCE_DMG" ]]; then
        if [[ -f "$REFERENCE_DMG" ]]; then
            inspect_dmg r3 "$REFERENCE_DMG" release
        else
            fail r3 "reference DMG not found: $REFERENCE_DMG"
        fi
    fi
fi

# ---- (b) First launch ------------------------------------------------------------
section "(b) First launch"
if (( HEADLESS == 1 )) || [[ -z "$APP" ]]; then
    skip b "no GUI launch in a headless run"
elif ! /usr/sbin/ioreg -n Root -d1 -a | python3 -c '
import plistlib, sys
root = plistlib.loads(sys.stdin.buffer.read())
root = root[0] if isinstance(root, list) else root
uid = int(sys.argv[1])
sessions = [s for s in root.get("IOConsoleUsers", []) if s.get("kCGSSessionOnConsoleKey") and s.get("kCGSSessionUserIDKey") == uid]
if not sessions:
    raise SystemExit("no login session for this user at the console")
print("locked" if sessions[0].get("CGSSessionScreenIsLocked") else "unlocked")
' "$(id -u)" > "$H/session.txt" 2>&1; then
    skip b "no GUI login session for this user: $(tail -n 1 "$H/session.txt")"
else
    # A locked screen still runs the app and setup; they are only not seen.
    [[ "$(cat "$H/session.txt")" == "locked" ]] && printf 'note: the screen is locked; setup runs but is not visible\n'

    if [[ "$APP" == /Applications/* ]]; then
        fail b "refusing to launch an app inside /Applications"
    else
        # The existing gate, with this run's home kept for inspection.
        if env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$E2E_TMP/" LANG="${LANG:-en_US.UTF-8}" USER="${USER:-e2e}" \
            HOME="$HOME" VERIFY_HOME="$E2E_HOME" VERIFY_EVIDENCE="$H/first-launch.txt" \
            VERIFY_EXPECT_ONBOARDING=1 VERIFY_WAIT_SECONDS=20 \
            "$SCRIPT_DIR/verify-app-launches.sh" "$APP" > "$H/first-launch.log" 2>&1; then
            pass b1 "launched from the built bundle under the throwaway HOME: alive for 20 s, setup (onboarding) up the whole time (screen $(cat "$H/session.txt"))"
        else
            fail b1 "launch gate: $(grep -E 'FAIL|ERROR' "$H/first-launch.log" | tail -n 1)"
        fi
        if grep -q -- '--capture' "$H/first-launch.txt" 2>/dev/null; then
            fail b2 "a process ran with --capture before consent: $(grep -- '--capture' "$H/first-launch.txt" | head -n 1)"
        else
            pass b2 "no process ran with --capture before consent (capture is argv-gated: ADR-0013 amendment 1 §4); started: $(grep -c '^started=' "$H/first-launch.txt" 2>/dev/null || echo 0) processes"
        fi
        if grep -q 'HippocampusOCR/hippocampus-ocr' "$H/first-launch.txt" 2>/dev/null; then
            fail b3 "the OCR worker started before consent"
        else
            pass b3 "the OCR worker never started before consent"
        fi
        # Nothing remembered: no screenshots and no stored moments.
        blobs_before="$(find "$SUPPORT/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$blobs_before" == "0" ]]; then
            pass b4 "no screenshot was kept before consent (blobs: none)"
        else
            fail b4 "$blobs_before screenshot blob(s) exist before consent"
        fi
        if [[ ! -f "$DB" ]]; then
            pass b5 "no memory database exists before consent"
        elif [[ -f "$KEY_FILE" ]]; then
            events="$(product_env "$BRAIN_CLI" stats --json 2>/dev/null | json_field 'v["event_count"]' 2>/dev/null)"
            [[ "$events" == "0" ]] && pass b5 "the memory database holds 0 moments before consent" \
                || fail b5 "the memory database holds ${events:-?} moment(s) before consent"
        else
            fail b5 "a database exists before consent and no key was made to read it"
        fi
        if [[ -f "$E2E_HOME/.config/hippocampus/runtime.toml" ]] && grep -q '^capture_enabled = true' "$E2E_HOME/.config/hippocampus/runtime.toml"; then
            fail b6 "remembering is on before consent (runtime.toml)"
        else
            pass b6 "remembering is off before consent"
        fi
        (cd "$E2E_HOME" && find . -mindepth 1 \( -type f -o -type d \) -exec stat -f '%Sp %N' {} + 2>/dev/null | sort -k2) > "$H/first-launch-files.txt"
        person b7 "Clicking through setup, granting Screen Recording and Accessibility, and seeing what Try it reads need a person (HUMAN-CHECKLIST steps 2-3)"
    fi
fi

# ---- (c) Memory pipeline with synthetic screens -----------------------------
section "(c) Memory pipeline with synthetic screens"
# Product programs work in the throwaway home, so anything one leaves in its
# working folder lands where the audit and the uninstall check look.
cd "$E2E_HOME" || exit 1
if [[ -n "$APP" ]]; then
    AGENT="$APP/Contents/MacOS/mci-agent"
else
    AGENT="$REPO_ROOT/target/debug/mci-agent"
    E2E_EXTRA_ENV+=(MCI_EMBEDDER_DISABLED=1)
fi
# Background work never calls a model; Ask may (see c5).
NO_MODEL=(env MCI_MIND_PATH=/nonexistent/hippocampus-mind)

# Custody: the development file key, as the app's FileKeyStore makes it
# (folder by createDirectory with no attributes, under the app's umask 077,
# so 0700; key file 0600).
mkdir -p "$(dirname "$SUPPORT")"
( umask 077; mkdir -p "$SUPPORT" )
( umask 077; openssl rand -hex 32 > "$KEY_FILE" )
chmod 600 "$KEY_FILE"
KEY_HEX="$(tr -d '\r\n' < "$KEY_FILE")"
printf '{}\n' > "$E2E_HOME/.claude.json"
mkdir -p "$E2E_HOME/.codex" && : > "$E2E_HOME/.codex/config.toml"
if [[ ${#KEY_HEX} -eq 64 && "$(stat -f '%Lp' "$KEY_FILE")" == "600" ]]; then
    pass c1 "development key custody: a 32-byte key in MCI/dev.key (0600); the Keychain service given to every program does not exist"
else
    fail c1 "development key was not created correctly"
fi

# The engine contract that already exists (seeded history, a production wire
# frame, MCP, client registration, deletion and uninstall), in its own
# throwaway home.
if (cd "$REPO_ROOT" && env -i HOME="$HOME" USER="${USER:-e2e}" TMPDIR="$E2E_TMP/" LANG="${LANG:-en_US.UTF-8}" PATH="$PATH" \
    "$SCRIPT_DIR/e2e-clean-home.sh") > "$H/e2e-clean-home.log" 2>&1; then
    pass c0 "scripts/e2e-clean-home.sh: $(tail -n 1 "$H/e2e-clean-home.log" | sed 's/^PASS: //')"
else
    fail c0 "scripts/e2e-clean-home.sh: $(grep FAIL "$H/e2e-clean-home.log" | tail -n 1)"
fi

# The synthetic day. Marker words name each moment; secrets carry their own.
cat > "$H/frames.json" <<'FRAMES'
{"frames": [
 {"id": "notes-larkspur", "app": "com.apple.Notes", "title": "Larkspur launch checklist", "offset_seconds": -3000,
  "lines": ["Larkspur launch checklist", "Send the Quillfeather draft to the review group by Thursday.", "Confirm the venue for the launch party.", "Ask Dana for the final pricing table."]},
 {"id": "code-kestrel", "app": "com.microsoft.VSCode", "title": "ledger.rs - kestrel-ledger", "offset_seconds": -2400,
  "lines": ["// Kestrel ledger reconciliation for the quarterly audit", "fn reconcile(entries: &[Entry]) -> Balance {", "    let total = entries.iter().map(|e| e.amount).sum();", "    Balance::new(total)", "}"]},
 {"id": "mail-heron", "app": "com.apple.mail", "title": "Heron supplier quote", "offset_seconds": -1800,
  "lines": ["From: Heron Supplies", "Subject: Heron supplier quote", "The quote for forty oak desks is valid until Friday."]},
 {"id": "chat-marigold", "app": "com.tinyspeck.slackmacgap", "title": "marigold-demo (Channel) - Synthetic Co - Slack", "offset_seconds": -1200,
  "lines": ["# marigold-demo", "Priya: The Marigold demo moves to Wednesday at 2pm.", "Sam: I will update the slides tonight."]},
 {"id": "forget-pelican", "app": "com.apple.Notes", "title": "Pelican travel notes", "offset_seconds": -900,
  "lines": ["Pelican travel notes", "Train to Lisbon leaves at 9:40 from platform four."]},
 {"id": "range-osprey-1", "app": "com.apple.TextEdit", "title": "Osprey budget draft.rtf", "offset_seconds": -11100,
  "lines": ["Osprey budget draft", "Line items for the spring offsite: venue, meals, travel."]},
 {"id": "range-osprey-2", "app": "com.apple.TextEdit", "title": "Osprey budget draft.rtf", "offset_seconds": -10800,
  "lines": ["Osprey budget draft", "Second pass: trim travel by fifteen percent."]},
 {"id": "retention-wombat", "app": "com.apple.Notes", "title": "Wombat archive notes", "offset_seconds": -1728000,
  "lines": ["Wombat archive notes", "Old reading list from last month."]},
 {"id": "url-token-larch", "app": "com.apple.Safari", "title": "Larch Workspace", "offset_seconds": -600,
  "url": "https://app.larch.example/auth/callback?access_token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJsYXJjaCJ9.TGFyY2hTZWNyZXRTaWduYXR1cmU",
  "lines": ["app.larch.example", "Larch workspace dashboard", "Welcome back. Three projects were updated today."]},
 {"id": "secret-card", "app": "com.apple.Preview", "title": "Saffron receipt.pdf", "offset_seconds": -500,
  "lines": ["Saffron order receipt", "Card number 4242 4242 4242 4242", "Expires 12/29"]},
 {"id": "secret-otp", "app": "com.apple.MobileSMS", "title": "Messages", "offset_seconds": -450,
  "lines": ["Cobalt Bank", "Your verification code is 739104. Do not share it."]},
 {"id": "secret-github-token", "app": "com.apple.Terminal", "title": "zsh", "offset_seconds": -400,
  "lines": ["Tamarack deploy notes", "New token: ghp_R8nQ2vLx7Tz4Kp9Wm3Yc5Hb6Jd1Fs0Ag2Ue8"]},
 {"id": "secret-aws-key", "app": "com.apple.Terminal", "title": "zsh", "offset_seconds": -350,
  "lines": ["Juniper staging credentials", "AKIAQZ7R4XW2N6M3JH5P"]},
 {"id": "secret-jwt", "app": "com.apple.TextEdit", "title": "Thistle notes.txt", "offset_seconds": -300,
  "lines": ["Thistle session", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0aGlzdGxlIn0.VGhpc3RsZVNpZ25hdHVyZQ"]},
 {"id": "secret-password", "app": "com.apple.Notes", "title": "Bluebell house notes", "offset_seconds": -250,
  "lines": ["Bluebell house notes", "Wi-Fi password: Orbit-Lantern-77"]},
 {"id": "secret-bare-api-key", "app": "com.apple.Terminal", "title": "zsh", "offset_seconds": -200,
  "lines": ["Bramble agent setup", "sk-ant-api03-Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0"]}
]}
FRAMES
ORDINARY_IDS="notes-larkspur code-kestrel mail-heron chat-marigold forget-pelican range-osprey-1 range-osprey-2 retention-wombat url-token-larch"
SECRET_IDS="secret-card secret-otp secret-github-token secret-aws-key secret-jwt secret-password secret-bare-api-key"
# Markers for the audit: every word that names a moment, and every secret.
cat > "$H/markers.txt" <<'MARKERS'
moment	Larkspur
moment	Quillfeather
moment	Kestrel
moment	Heron Supplies
moment	Marigold
moment	Pelican
moment	Osprey
moment	Wombat
moment	Larch workspace
secret	Saffron
secret	4242 4242 4242 4242
secret	4242424242424242
secret	Cobalt
secret	739104
secret	Tamarack
secret	ghp_R8nQ2vLx7Tz4Kp9Wm3Yc5Hb6Jd1Fs0Ag2Ue8
secret	R8nQ2vLx7Tz4
secret	Juniper
secret	AKIAQZ7R4XW2N6M3JH5P
secret	Thistle
secret	VGhpc3RsZVNpZ25hdHVyZQ
secret	Bluebell
secret	Orbit-Lantern-77
secret	Bramble
secret	sk-ant-api03-Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0
secret	Qm7Zp2Lr9Xw4
secret	TGFyY2hTZWNyZXRTaWduYXR1cmU
secret	access_token=eyJ
MARKERS

OCR_WORKER=""
case "$OCR_CHOICE" in
    paddle|auto)
        for candidate in "${APP:+$APP/Contents/Resources/HippocampusOCR/hippocampus-ocr}" \
            "$REPO_ROOT/tools/ocr/dist/hippocampus-ocr/hippocampus-ocr"; do
            [[ -n "$candidate" && -x "$candidate" ]] && { OCR_WORKER="$candidate"; break; }
        done
        ;;
esac
FEED_ARGS=(--manifest "$H/frames.json" --report "$H/feed-report.json")
if [[ -n "$OCR_WORKER" && "$OCR_SANDBOX" == "1" ]]; then
    # The helper starts the worker inside the product's own sandbox, which
    # denies every network operation and name lookups (OCRWorkerSandbox),
    # with ONNX Runtime's telemetry turned off. A sandbox can't be applied
    # inside another, so the test's rules are added to that profile rather
    # than wrapping the worker: the real ~/Library is closed to it as well.
    # Any attempt still shows in the unified log and the kernel's sandbox
    # reports, which the audit reads.
    real_library="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')/Library"
    printf '(deny file-read* file-write* (subpath "%s"))\n' "$real_library" > "$H/ocr-sandbox-rules.sb"
    FEED_ARGS+=(--worker "$OCR_WORKER" --worker-sandbox-rules "$H/ocr-sandbox-rules.sb")
    READER="the bundled PP-OCR worker ($OCR_WORKER, inside the product's no-network sandbox, with the real ~/Library closed too)"
elif [[ -n "$OCR_WORKER" ]]; then
    FEED_ARGS+=(--worker "$OCR_WORKER")
    READER="the bundled PP-OCR worker ($OCR_WORKER, inside the product's no-network sandbox only: --allow-ocr-network)"
elif [[ "$OCR_CHOICE" == "paddle" ]]; then
    fail c2 "--ocr paddle: no PP-OCR worker in the app or tools/ocr/dist"
    READER=""
else
    # Vision under load can take longer than the helper's 1 s deadline.
    FEED_ARGS+=(--timeout-ms 20000)
    READER="Apple Vision (no bundled worker; deadline raised to 20 s)"
fi

# The helper's pipeline in fixture mode, into the agent exactly as the app
# runs it (mci-agent --drain-stdin --strict --db-path). While it drains, the
# WAL and SHM are copied for the audit.
mkdir -p "$H/wal-snapshots"
(
    while [[ -f "$H/.sampling" && ! -f "$H/.drain-done" ]]; do
        for suffix in wal shm; do
            [[ -s "$DB-$suffix" ]] && cp "$DB-$suffix" "$H/wal-snapshots/mci.sqlite-$suffix.$(date +%s)" 2>/dev/null
        done
        sleep 2
    done
) &
SNAPSHOT_PID=$!
drain_start=$SECONDS
if [[ -n "$READER" ]]; then
    product_env "${NO_MODEL[@]}" "$FEED" "${FEED_ARGS[@]}" 2> "$H/feed.stderr" \
        | product_env "${NO_MODEL[@]}" "$AGENT" --drain-stdin --strict --db-path "$DB" \
            > "$H/agent-drain.stdout" 2> "$H/agent-drain.stderr"
    pipeline_status=("${PIPESTATUS[@]}")
else
    pipeline_status=(1 1)
fi
: > "$H/.drain-done"
wait "$SNAPSHOT_PID" 2>/dev/null
drain_seconds=$((SECONDS - drain_start))
if [[ "${pipeline_status[0]}" == "0" && "${pipeline_status[1]}" == "0" ]] && [[ -f "$H/feed-report.json" ]]; then
    pass c2 "16 synthetic windows read by $READER and drained by the bundled agent in ${drain_seconds}s ($(grep -Eo 'drained [0-9]+ frame\(s\)[^;]*; [0-9]+ logged, [0-9]+ non-health, [0-9]+ to brain' "$H/agent-drain.stderr" | tail -n 1))"
else
    fail c2 "pipeline exit codes feed=${pipeline_status[0]} agent=${pipeline_status[1]}: $(tail -n 1 "$H/feed.stderr")"
fi

# Each ordinary window became one moment with a sealed screenshot; each secret
# window became a privacy tombstone (reason 6: OCR-time secret).
python3 - "$H/feed-report.json" "$ORDINARY_IDS" "$SECRET_IDS" > "$H/feed-verdicts.txt" 2>&1 <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
frames = {f["id"]: f for f in report["frames"]}
for fid in sys.argv[2].split():
    f = frames.get(fid, {})
    ok = f.get("events") == 1 and f.get("screenshot_sealed") and f.get("tombstones") == 0
    print(("PASS" if ok else "FAIL"), "ordinary", fid, json.dumps(f, sort_keys=True))
for fid in sys.argv[3].split():
    f = frames.get(fid, {})
    ok = f.get("events") == 0 and f.get("tombstones", 0) >= 1 and not f.get("screenshot_sealed")
    print(("PASS" if ok else "FAIL"), "secret", fid, json.dumps(f, sort_keys=True))
PY
ordinary_ok="$(grep -c '^PASS ordinary' "$H/feed-verdicts.txt")"
if [[ "$ordinary_ok" == "9" ]]; then
    pass c3 "all 9 ordinary windows became moments, each with a sealed screenshot"
else
    fail c3 "$ordinary_ok of 9 ordinary windows became moments: $(grep '^FAIL ordinary' "$H/feed-verdicts.txt" | cut -d' ' -f3 | tr '\n' ' ')"
fi

# The memory as the window reads it (mci-brain-ffi through FFIBrainReader).
product_env "${NO_MODEL[@]}" "$AGENT" enrich --db-path "$DB" --batch-size 32 > "$H/enrich.stdout" 2> "$H/enrich.stderr"
product_env "$PROBE" history 200 > "$H/history.json" 2> "$H/history.stderr"
python3 - "$H/history.json" > "$H/history-verdicts.txt" 2>&1 <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
want = {"Larkspur": "notes", "Kestrel": "code", "Heron": "mail", "Marigold": "chat", "Pelican": "notes",
        "Osprey": "text", "Wombat": "notes", "Larch": "safari"}
for word in want:
    hit = [r for r in rows if word.lower() in (r.get("snippet", "") + " " + (r.get("title") or "")).lower()]
    if not hit:
        print("FAIL", word, "no History row"); continue
    r = hit[0]
    print("PASS" if r.get("screenshot_path") and "/MCI/blobs/" in r["screenshot_path"] else "FAIL", word,
          json.dumps({"event_id": r["event_id"], "caption": r.get("caption"), "title": r.get("title"),
                      "screenshot": bool(r.get("screenshot_path"))}, sort_keys=True))
print("ROWS", len(rows))
print("CAPTIONS", sum(1 for r in rows if r.get("caption")))
PY
history_rows="$(sed -n 's/^ROWS //p' "$H/history-verdicts.txt")"
history_captions="$(sed -n 's/^CAPTIONS //p' "$H/history-verdicts.txt")"
if ! grep -q '^FAIL' "$H/history-verdicts.txt"; then
    pass c4 "History (FFIBrainReader.recentEvents) lists every ordinary moment, each with its screenshot under MCI/blobs ($history_rows rows; 9 ordinary windows were shown)"
else
    fail c4 "History: ${history_rows:-0} rows; $(grep '^FAIL' "$H/history-verdicts.txt" | head -n 2 | tr '\n' ' ')"
fi
[[ "$history_rows" == "9" ]] || fail c4.count "History has $history_rows rows for 9 ordinary windows: a secret window reached the memory (see c8)"
if [[ -n "$history_captions" && "$history_captions" -ge 5 ]]; then
    pass c4.caption "$history_captions of $history_rows History rows lead with a caption made on this Mac without a model (from the window title)"
else
    fail c4.caption "only ${history_captions:-0} of ${history_rows:-0} History rows have a caption"
fi
larkspur_id="$(grep '^PASS Larkspur' "$H/history-verdicts.txt" | python3 -c 'import json,sys; l=sys.stdin.read().split(" ",2); print(json.loads(l[2])["event_id"]) if len(l) > 2 else print("")')"
if [[ -n "$larkspur_id" ]]; then
    product_env "$PROBE" reading "$larkspur_id" > "$H/reading.json" 2>&1
    if python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
assert "Quillfeather" in r["main"], "main text lacks the moment"
assert "Larkspur launch checklist" in r["main"] or "Larkspur launch checklist" in r["rest"]
' "$H/reading.json" 2>"$H/reading.err"; then
        pass c4.reading "the moment's clean text (main) reads 'Send the Quillfeather draft...'; the window's title bar is set apart in rest"
    else
        fail c4.reading "clean text: $(tail -n 1 "$H/reading.err")"
    fi
    product_env "$PROBE" screenshot "$larkspur_id" > "$H/screenshot.json" 2>&1
    if python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
assert r["screenshot"] == "decrypted" and r["kind"] == "jpeg", r
assert r["width"] == "2200" and r["height"] == "1400", r
' "$H/screenshot.json" 2>"$H/screenshot.err"; then
        pass c4.screenshot "the screenshot reference opens the way the window opens it: a 2200x1400 JPEG, decrypted in memory"
    else
        fail c4.screenshot "screenshot: $(tail -n 1 "$H/screenshot.err")"
    fi
else
    fail c4.reading "no Larkspur moment to read"
fi

# Search and Ask: the command line, the window's search and MCP.
product_env "$BRAIN_CLI" search Quillfeather --json > "$H/search-cli.json" 2>&1
grep -q '"event_id"' "$H/search-cli.json" && grep -q 'Quillfeather' "$H/search-cli.json" \
    && pass c5.search "mci-brain search finds the Quillfeather moment" \
    || fail c5.search "mci-brain search did not find the Quillfeather moment"
product_env "$PROBE" search Marigold demo > "$H/search-window.json" 2>&1
grep -q 'Marigold' "$H/search-window.json" \
    && pass c5.window-search "the window's search (FFIBrainReader.search) finds the Marigold moment" \
    || fail c5.window-search "the window's search did not find the Marigold moment"

run_mcp() {
    # $1 output file, $2 extra mcp-serve flag or "", then JSON-RPC requests.
    # Kept open until every request is answered, as an AI tool keeps it.
    local out="$1" flag="$2"
    shift 2
    printf '%s\n' "$@" > "$out.requests"
    if [[ -n "$flag" ]]; then
        product_env python3 "$SCRIPT_DIR/lib/e2e_mcp.py" --out "$out" --timeout 240 -- \
            "$AGENT" --db-path "$DB" mcp-serve "$flag" < "$out.requests" 2> "$out.stderr"
    else
        product_env "${NO_MODEL[@]}" python3 "$SCRIPT_DIR/lib/e2e_mcp.py" --out "$out" --timeout 120 -- \
            "$AGENT" --db-path "$DB" mcp-serve < "$out.requests" 2> "$out.stderr"
    fi
}
run_mcp "$H/mcp.jsonl" "" \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"recall","arguments":{"query":"Quillfeather draft","limit":5}}}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"events_since","arguments":{"ts_us":0,"limit":500}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"stats","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"context","arguments":{"focus":"Larkspur launch checklist","max_tokens":600,"max_evidence":12}}}' \
    '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"episodes","arguments":{"limit":20}}}' \
    '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"recall","arguments":{"query":"Saffron receipt card","limit":5}}}' \
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"recall","arguments":{"query":"Bramble agent setup","limit":5}}}' \
    '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"day","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"sessions","arguments":{}}}'
python3 - "$H/mcp.jsonl" > "$H/mcp-verdicts.txt" 2>&1 <<'PY'
import json, sys
responses = {}
for line in open(sys.argv[1]):
    if line.strip():
        r = json.loads(line); responses[r.get("id")] = r
def text(i): return json.dumps(responses.get(i, {}).get("result", {}))
tools = {t["name"] for t in responses.get(2, {}).get("result", {}).get("tools", [])}
print("TOOLS", " ".join(sorted(tools)))
print("RECALL", "Quillfeather" in text(3))
events = responses.get(4, {}).get("result", {}).get("events", [])
print("EVENTS", len(events))
print("CONTEXT", "Larkspur" in text(6) and "event" in text(6))
print("ERRORS", sum(1 for r in responses.values() if "error" in r))
PY
mcp_events="$(sed -n 's/^EVENTS //p' "$H/mcp-verdicts.txt")"
if grep -q '^RECALL True' "$H/mcp-verdicts.txt" && grep -q '^CONTEXT True' "$H/mcp-verdicts.txt" \
    && grep -q '^ERRORS 0' "$H/mcp-verdicts.txt" && [[ "$mcp_events" == "$history_rows" ]]; then
    pass c5.mcp "MCP (mcp-serve over stdio): tools/list ($(sed -n 's/^TOOLS //p' "$H/mcp-verdicts.txt" | wc -w | tr -d ' ') tools), recall finds Quillfeather, events_since returns all $mcp_events moments, context cites the Larkspur moment"
else
    fail c5.mcp "MCP: $(tr '\n' ' ' < "$H/mcp-verdicts.txt")"
fi

# Ask: the CLI and the Ask panel's own session (--assist), with the bundled
# model process when there is one (Apple Intelligence on this Mac, or none).
run_with_timeout 240 product_env "$AGENT" ask "When is the Quillfeather draft due?" --json \
    > "$H/ask-cli.json" 2> "$H/ask-cli.stderr"
ask_status=$?
python3 - "$H/ask-cli.json" > "$H/ask-verdict.txt" 2>&1 <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
blob = json.dumps(value)
print("SOURCE", "Quillfeather" in blob or "Larkspur" in blob)
answer = value.get("answer")
print("ANSWER", json.dumps(answer)[:300] if answer else "none (" + str(value.get("unavailable")) + ")")
print("KEYS", " ".join(sorted(value.keys())))
PY
if [[ "$ask_status" == "0" ]] && grep -q '^SOURCE True' "$H/ask-verdict.txt"; then
    pass c5.ask "mci-agent ask answers with the Quillfeather moment as a source; answer: $(sed -n 's/^ANSWER //p' "$H/ask-verdict.txt")"
else
    fail c5.ask "mci-agent ask (exit $ask_status): $(tr '\n' ' ' < "$H/ask-verdict.txt" | cut -c1-300) $(tail -n 1 "$H/ask-cli.stderr")"
fi
run_mcp "$H/mcp-assist.jsonl" --assist \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask","arguments":{"question":"What moves the Marigold demo?"}}}'
if grep -q '"id":2' "$H/mcp-assist.jsonl" && grep -q 'Marigold' "$H/mcp-assist.jsonl" && ! grep -q '"error"' "$H/mcp-assist.jsonl"; then
    pass c5.ask-mcp "the Ask panel's session (mcp-serve --assist, tool ask) answers from the Marigold moment"
else
    fail c5.ask-mcp "mcp-serve --assist ask: $(tail -c 300 "$H/mcp-assist.jsonl" 2>/dev/null) $(tail -n 1 "$H/mcp-assist.jsonl.stderr")"
fi

# Copy for Your AI and the handoff packet.
product_env "${NO_MODEL[@]}" "$AGENT" context --focus "Larkspur launch checklist" --format json --db-path "$DB" \
    > "$H/context.json" 2> "$H/context.stderr"
grep -q 'Quillfeather' "$H/context.json" && pass c6.context "mci-agent context (Copy for Your AI) cites the Larkspur moment" \
    || fail c6.context "mci-agent context lacks the Larkspur moment: $(tail -n 1 "$H/context.stderr")"
printf '{"to":"copy","question":"Larkspur launch checklist","moments":[%s]}' "${larkspur_id:-0}" \
    | product_env "${NO_MODEL[@]}" "$AGENT" send-card --json --db-path "$DB" > "$H/send-card.json" 2> "$H/send-card.stderr"
python3 -c '
import json, sys
card = json.load(open(sys.argv[1]))
assert card.get("copy") is True, card
assert "Quillfeather" in card["message"] or "Larkspur" in card["message"], "message lacks the moment"
' "$H/send-card.json" 2> "$H/send-card.verdict" \
    && pass c6.card "send-card (the one builder for Ask {Tool} and Copy for Your AI) makes a copy card citing the moment; nothing is sent" \
    || fail c6.card "send-card: $(tail -n 1 "$H/send-card.verdict") $(tail -n 1 "$H/send-card.stderr")"
product_env "${NO_MODEL[@]}" "$AGENT" connect --all --no-refresh-agent --db-path "$DB" > "$H/connect.stdout" 2> "$H/connect.stderr"
if grep -q 'MCI_DB_KEYCHAIN_SERVICE' "$E2E_HOME/.claude.json" && grep -q 'MCI_DB_KEYCHAIN_SERVICE' "$E2E_HOME/.codex/config.toml" \
    && ! grep -qF "$KEY_HEX" "$E2E_HOME/.claude.json" "$E2E_HOME/.codex/config.toml" \
    && ! grep -q 'MCI_DB_KEY_HEX\|MCI_DEVELOPMENT_FILE_KEY\|dev\.key' "$E2E_HOME/.claude.json" "$E2E_HOME/.codex/config.toml"; then
    pass c6.connect "Connect AI Tools registers Claude Code and Codex with a Keychain reference, never the key (throwaway ~/.claude.json and ~/.codex)"
else
    fail c6.connect "client registration: $(tail -n 1 "$H/connect.stderr")"
fi
if MCI_E2E_HANDOFF_OUT="$H/handoff-packets.txt" product_env "${NO_MODEL[@]}" env MCI_E2E_HANDOFF_OUT="$H/handoff-packets.txt" \
    "$SCRIPT_DIR/e2e-handoff.sh" --synthetic "$AGENT" > "$H/handoff.log" 2>&1; then
    pass c6.handoff "handoff packet (e2e-handoff.sh --synthetic): $(tail -n 1 "$H/handoff.log" | sed 's/^== //'); decision, next step, citations, disclaimer, claude-hook and codex-hook envelopes"
else
    fail c6.handoff "handoff: $(grep 'FAIL' "$H/handoff.log" | head -n 2 | tr '\n' ' ')"
fi
person c6.live "A fresh, logged-in Claude Code or Codex session starting with the packet needs a person (scripts/e2e-handoff.sh without --synthetic)"

# Resume's plan (a seam on this branch).
product_env "${NO_MODEL[@]}" "$AGENT" work --json --db-path "$DB" > "$H/work.json" 2> "$H/work.stderr"
product_env "${NO_MODEL[@]}" "$AGENT" resume-plan --item w_e2e000 --json --db-path "$DB" > "$H/resume-plan.json" 2> "$H/resume-plan.stderr"
if python3 -c '
import json, sys
work = json.load(open(sys.argv[1])); plan = json.load(open(sys.argv[2]))
assert isinstance(work.get("items"), list) and plan == {"items": []}, (work, plan)
' "$H/work.json" "$H/resume-plan.json" 2>/dev/null; then
    pass c7 "Resume's plan answers in the shape the window decodes ({\"items\": []}); it is a seam on this branch, so nothing is offered to reopen yet"
else
    fail c7 "resume-plan/work: $(cat "$H/resume-plan.json" "$H/resume-plan.stderr" | tail -n 2 | tr '\n' ' ')"
fi

# Secret redaction: each secret window was dropped before the store.
secret_frames_ok="$(grep -c '^PASS secret' "$H/feed-verdicts.txt")"
product_env "$BRAIN_CLI" export --format jsonl --out "$H/brain-export.jsonl" > /dev/null 2> "$H/brain-export.stderr"
python3 - "$H/brain-export.jsonl" "$H/markers.txt" "$H/frames.json" > "$H/secret-verdicts.txt" 2>&1 <<'PY'
import json, sys
store = open(sys.argv[1], encoding="utf-8", errors="replace").read()
markers = [line.rstrip("\n").split("\t", 1) for line in open(sys.argv[2]) if line.strip()]
url_markers = {"TGFyY2hTZWNyZXRTaWduYXR1cmU", "access_token=eyJ"}
for kind, marker in markers:
    if kind != "secret":
        continue
    where = "URL" if marker in url_markers else "SCREEN"
    print(("LEAK" if marker in store else "ABSENT"), where, marker)
PY
leaks="$(grep -c '^LEAK SCREEN' "$H/secret-verdicts.txt")"
url_leaks="$(grep -c '^LEAK URL' "$H/secret-verdicts.txt")"
if [[ "$secret_frames_ok" == "7" ]]; then
    pass c8.frames "all 7 secret windows (card, one-time code, GitHub token, AWS key, JWT, password line, bare API key) were dropped as privacy tombstones before the store"
else
    fail c8.frames "$secret_frames_ok of 7 secret windows were dropped; reached the store: $(grep '^FAIL secret' "$H/feed-verdicts.txt" | cut -d' ' -f3 | tr '\n' ' ')"
fi
if [[ "$leaks" == "0" ]]; then
    pass c8.store "the decrypted memory (mci-brain export) holds none of the secret markers shown on screen"
else
    fail c8.store "on-screen secret text reached the decrypted memory: $(grep '^LEAK SCREEN' "$H/secret-verdicts.txt" | cut -d' ' -f3- | tr '\n' ';' | cut -c1-300)"
fi
if [[ "$url_leaks" == "0" ]]; then
    pass c8.url "an access token in the page address (shown only as the site name, as Safari shows it) did not reach the memory"
else
    fail c8.url "an access token in the page address reached the memory: the window's text showed only app.larch.example, so the OCR-time checks passed it, and the URL is stored as the browser reported it (the token's signature and access_token=eyJ… are in mci-brain export)"
fi
if grep -q '"Saffron\|Bramble' "$H/mcp.jsonl"; then
    fail c8.recall "MCP recall returns a secret window's text"
else
    pass c8.recall "MCP recall for the card and API-key windows' words returns nothing from them"
fi

# ---- (d) Forgetting and retention -------------------------------------------
section "(d) Forgetting and retention"
blob_count() { find "$SUPPORT/blobs" -type f -name '*.bin' 2>/dev/null | wc -l | tr -d ' '; }
history_id() {
    python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))
ids = [str(r["event_id"]) for r in rows if sys.argv[2].lower() in ((r.get("title") or "") + " " + r.get("snippet", "")).lower()]
print(" ".join(ids))
' "$H/history.json" "$1"
}
history_field() {
    python3 -c '
import json, sys
rows = {str(r["event_id"]): r for r in json.load(open(sys.argv[1]))}
print(rows.get(sys.argv[2], {}).get(sys.argv[3]) or "")
' "$H/history.json" "$1" "$2"
}
gone_everywhere() {
    # $1 step, $2 marker word, $3 screenshot paths (space separated)
    local step="$1" word="$2" shots="$3" found="" path
    product_env "$PROBE" history 200 > "$H/history-after-$step.json" 2>/dev/null
    grep -qi "$word" "$H/history-after-$step.json" && found="$found History;"
    product_env "$PROBE" search "$word" > "$H/search-after-$step.json" 2>/dev/null
    grep -qi "$word" "$H/search-after-$step.json" && found="$found window-search;"
    product_env "$BRAIN_CLI" search "$word" --json > "$H/cli-search-after-$step.json" 2>/dev/null
    grep -qi "$word" "$H/cli-search-after-$step.json" && found="$found mci-brain-search;"
    product_env "$BRAIN_CLI" export --format jsonl --out "$H/export-after-$step.jsonl" > /dev/null 2>&1
    grep -qi "$word" "$H/export-after-$step.jsonl" && found="$found decrypted-export;"
    run_mcp "$H/mcp-after-$step.jsonl" "" \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"recall\",\"arguments\":{\"query\":\"$word\",\"limit\":10}}}" \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"events_since","arguments":{"ts_us":0,"limit":500}}}' \
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"context\",\"arguments\":{\"focus\":\"$word\",\"max_tokens\":600,\"max_evidence\":12}}}" \
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"episodes","arguments":{"limit":50}}}' \
        '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"sessions","arguments":{}}}' \
        '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"day","arguments":{}}}'
    # The word itself is the query and the focus: look only at what came back.
    local mcp_hits
    mcp_hits="$(python3 - "$H/mcp-after-$step.jsonl" "$word" <<'PY'
import json, sys
word = sys.argv[2].lower()
def strip(value):
    if isinstance(value, dict):
        return {k: strip(v) for k, v in value.items() if k not in ("query", "focus", "question")}
    if isinstance(value, list):
        return [strip(v) for v in value]
    if isinstance(value, str):
        if value.lower() == word:
            return ""
        if value.lstrip().startswith(("{", "[")):
            try:
                return strip(json.loads(value))  # MCP text content holds the answer as JSON
            except ValueError:
                return value
    return value
hits = []
for line in open(sys.argv[1]):
    if not line.strip():
        continue
    response = json.loads(line)
    text = json.dumps(strip(response.get("result", {}))).lower()
    for echo in ("focus: " + word, "about " + word, '"' + word + '"'):
        text = text.replace(echo, "")
    if word in text:
        hits.append(str(response.get("id")))
print(",".join(hits))
PY
)"
    [[ -n "$mcp_hits" ]] && found="$found MCP(ids $mcp_hits);"
    for path in $shots; do
        [[ -e "$path" ]] && found="$found screenshot-file;"
    done
    printf '%s' "$found"
}

pelican_id="$(history_id Pelican)"
pelican_shot="$(history_field "$pelican_id" screenshot_path)"
blobs_before_forget="$(blob_count)"
if [[ -n "$pelican_id" ]]; then
    product_env "$PROBE" forget "$pelican_id" > "$H/forget-one.json" 2> "$H/forget-one.stderr"
    if python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
assert r == {"committed": "true", "events_deleted": "1", "vacuum_ok": "true", "blob_cleanup_ok": "true"}, r
' "$H/forget-one.json" 2> "$H/forget-one.verdict"; then
        pass d1 "Forget one moment through the window's reader: 1 deleted, database rewritten (VACUUM), screenshot cleanup done"
    else
        fail d1 "Forget one moment: $(tail -n 1 "$H/forget-one.verdict") $(tail -n 1 "$H/forget-one.stderr")"
    fi
    leftovers="$(gone_everywhere d1 Pelican "$pelican_shot")"
    if [[ -z "$leftovers" ]]; then
        pass d1.gone "the forgotten moment is gone from History, both searches, the decrypted memory, MCP (recall, events, context, sessions, day) and its screenshot file"
    else
        fail d1.gone "the forgotten Pelican moment is still found in:$leftovers"
    fi
    product_env "$BRAIN_CLI" show "$pelican_id" --json > /dev/null 2>&1 \
        && fail d1.show "mci-brain show $pelican_id still reads the forgotten moment" \
        || pass d1.show "mci-brain show $pelican_id finds nothing"
else
    fail d1 "no Pelican moment to forget"
fi

osprey_ids="$(history_id Osprey)"
range="$(python3 -c '
import json, sys
rows = [r for r in json.load(open(sys.argv[1])) if str(r["event_id"]) in sys.argv[2].split()]
print(min(r["ts_us"] for r in rows) - 1_000_000, max(r["ts_us"] for r in rows) + 1_000_000) if rows else print("")
' "$H/history.json" "$osprey_ids")"
osprey_shots=""
for id in $osprey_ids; do osprey_shots="$osprey_shots $(history_field "$id" screenshot_path)"; done
if [[ -n "$range" ]]; then
    # shellcheck disable=SC2086
    product_env "$PROBE" forget-range $range > "$H/forget-range.json" 2> "$H/forget-range.stderr"
    if python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
assert r["committed"] == "true" and r["events_deleted"] == "2" and r["vacuum_ok"] == "true" and r["blob_cleanup_ok"] == "true", r
' "$H/forget-range.json" 2> "$H/forget-range.verdict"; then
        pass d2 "delete a time range through the window's reader: the 2 moments in it deleted, database rewritten, screenshots cleaned"
    else
        fail d2 "delete a time range: $(tail -n 1 "$H/forget-range.verdict") $(tail -n 1 "$H/forget-range.stderr")"
    fi
    leftovers="$(gone_everywhere d2 Osprey "$osprey_shots")"
    [[ -z "$leftovers" ]] && pass d2.gone "the range's moments are gone from History, searches, the decrypted memory, MCP and their screenshot files" \
        || fail d2.gone "the deleted Osprey moments are still found in:$leftovers"
else
    fail d2 "no Osprey moments to delete"
fi

# Retention: a 7-day keep window, applied by the agent's retention worker the
# way the app's agent applies it (its first cycle runs as it starts).
wombat_id="$(history_id Wombat)"
wombat_shot="$(history_field "$wombat_id" screenshot_path)"
printf '{"schema_version":2,"mode":"custom","days":7,"updated_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SUPPORT/retention.json"
chmod 600 "$SUPPORT/retention.json"
(
    deadline=$((SECONDS + 90))
    while (( SECONDS < deadline )); do
        grep -q 'retention purge: events=' "$H/agent-retention.stderr" 2>/dev/null && break
        sleep 1
    done
    sleep 2
) | product_env "${NO_MODEL[@]}" "$AGENT" --drain-stdin --strict --db-path "$DB" > "$H/agent-retention.stdout" 2> "$H/agent-retention.stderr"
if grep -q 'retention purge: events=1 ' "$H/agent-retention.stderr"; then
    pass d3 "retention (7 days) purged the 20-day-old moment: $(grep -o 'retention purge: [^,]*events=1[^$]*' "$H/agent-retention.stderr" | head -n 1 | cut -c1-160)"
else
    fail d3 "retention purge: $(grep 'retention' "$H/agent-retention.stderr" | tail -n 1)"
fi
leftovers="$(gone_everywhere d3 Wombat "$wombat_shot")"
[[ -z "$leftovers" ]] && pass d3.gone "the expired moment is gone from History, searches, the decrypted memory, MCP and its screenshot file" \
    || fail d3.gone "the expired Wombat moment is still found in:$leftovers"
remaining_blobs="$(blob_count)"
if [[ "$remaining_blobs" == "$((blobs_before_forget - 4))" ]]; then
    pass d4 "screenshots: $blobs_before_forget before, $remaining_blobs after (one per forgotten or expired moment removed)"
else
    fail d4 "screenshots: $blobs_before_forget before, $remaining_blobs after (expected $((blobs_before_forget - 4)))"
fi

# ---- Storage-security audit ---------------------------------------------------
if (( AUDIT == 1 )); then
    section "Storage-security audit (scripts/audit-storage-security.sh)"
    rm -f "$H/.sampling"
    wait "$SAMPLER_PID" 2>/dev/null
    SAMPLER_PID=""
    # What the product handed out: MCP answers, packets, the card, Ask.
    ls "$H"/mcp*.jsonl "$H/handoff-packets.txt" "$H/send-card.json" "$H/context.json" \
        "$H/ask-cli.json" 2>/dev/null > "$H/outputs.txt"
    # The shipped binaries: the app bundle, or the loose ones a headless run used.
    BINARIES=()
    if [[ -n "$APP" ]]; then
        BINARIES+=(--binaries "$APP")
    else
        BINARIES+=(--binaries "$AGENT")
        # The fixture feed started the worker, through the helper's own launch.
        [[ -n "$OCR_WORKER" ]] && BINARIES+=(--binaries "$(dirname "$OCR_WORKER")" --launcher "$FEED")
    fi
    if "$SCRIPT_DIR/audit-storage-security.sh" --home "$E2E_HOME" --tmpdir "$E2E_TMP" \
        --markers "$H/markers.txt" --key-file "$KEY_FILE" --wal-snapshots "$H/wal-snapshots" \
        --sampler "$H/sampler" --outputs "$H/outputs.txt" --keyframe-tool "$KEYFRAME_TOOL" \
        --since "$START_EPOCH" "${BINARIES[@]}" > "$H/audit.log" 2>&1; then
        pass audit "storage-security audit: $(tail -n 1 "$H/audit.log")"
    else
        fail audit "storage-security audit: $(tail -n 1 "$H/audit.log")"
    fi
    sed 's/^/    /' "$H/audit.log"
    : > "$H/.sampling"
    python3 "$SCRIPT_DIR/lib/e2e_sampler.py" --root-pid $$ --run-root "$RUN_ROOT" \
        --out-dir "$H/sampler-uninstall" --stop-file "$H/.sampling" --allow "$REPO_ROOT" \
        ${APP:+--allow "$APP"} > /dev/null 2>&1 &
    SAMPLER_PID=$!
fi

# ---- (e) Uninstall -------------------------------------------------------------
section "(e) Uninstall"
if (( HEADLESS == 0 )) && [[ -n "$APP" && "$APP" != /Applications/* ]]; then
    if env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$E2E_TMP/" LANG="${LANG:-en_US.UTF-8}" USER="${USER:-e2e}" HOME="$HOME" \
        "$SCRIPT_DIR/verify-quit-leaves-nothing.sh" "$APP" > "$H/quit.log" 2>&1; then
        pass e1 "Quit: $(tail -n 1 "$H/quit.log" | sed 's/^ok: //') (verify-quit-leaves-nothing.sh, its own throwaway home)"
    else
        fail e1 "Quit: $(grep FAIL "$H/quit.log" | tail -n 1)"
    fi
else
    skip e1 "Quit needs the app's GUI process (not in a headless run)"
fi
product_env "${NO_MODEL[@]}" "$AGENT" disconnect --all --no-refresh-agent > "$H/disconnect.stdout" 2> "$H/disconnect.stderr"
hooks_left=""
grep -q 'handoff' "$E2E_HOME/.claude/settings.json" 2>/dev/null && hooks_left="$hooks_left Claude Code SessionStart hook;"
grep -q 'handoff' "$E2E_HOME/.codex/hooks.json" 2>/dev/null && hooks_left="$hooks_left Codex hook;"
[[ -z "$hooks_left" ]] && pass e2 "mci-agent disconnect --all removed the session-start hooks from Claude Code and Codex" \
    || fail e2 "hooks left after disconnect:$hooks_left"

# The cask's zap list, applied to the throwaway home (as brew uninstall --zap).
CASK="$REPO_ROOT/../homebrew-tap/Casks/hippocampus.rb"
python3 - "$CASK" > "$H/zap-paths.txt" 2>/dev/null <<'PY' || true
import re, sys
text = open(sys.argv[1]).read()
block = text[text.index("zap "):]
block = block[:block.index("]") + 1]
for path in re.findall(r'"(~/[^"]+)"', block):
    print(path)
PY
if [[ ! -s "$H/zap-paths.txt" ]]; then
    # The cask lives in the local tap; without it, its home paths as of 0.3.1.
    printf '%s\n' "~/..claude.json.hippocampus.lock" "~/.claude/.hippocampus-context.lock" \
        "~/.codex/.config.toml.hippocampus.lock" "~/.codex/.hippocampus-context.lock" \
        "~/.config/hippocampus" "~/.hippocampus" "~/.hippocampus-client-registry-journal-*" "~/.mci" \
        "~/Library/Application Support/Hippocampus" "~/Library/Application Support/MCI" \
        "~/Library/Caches/ai.hippocampus" "~/Library/Caches/hippocampus-ocr" \
        "~/Library/Containers/ai.hippocampus.SafariExtension" "~/Library/Group Containers/group.ai.hippocampus" \
        "~/Library/HTTPStorages/ai.hippocampus" "~/Library/HTTPStorages/hippocampus-ocr" "~/Library/Logs/MCI" \
        "~/Library/Preferences/ai.hippocampus.plist" "~/Library/Saved Application State/ai.hippocampus.savedState" \
        > "$H/zap-paths.txt"
fi
# Without an app bundle (a headless run), the agent is the bare debug binary,
# and macOS names its caches (Core ML's compiled models) after it rather than
# after the bundle, Caches/ai.hippocampus, which the zap list has.
if [[ "$AGENT" != *.app/Contents/MacOS/* ]]; then
    printf '%s\n' "~/Library/Caches/$(basename "$AGENT")" >> "$H/zap-paths.txt"
fi
# Homebrew's zap expands globs (the AI-tool registry's lock files are one);
# so does this, inside the throwaway home only.
python3 - "$E2E_HOME" "$H/zap-paths.txt" <<'PY'
import glob, os, shutil, sys
home = os.path.realpath(sys.argv[1])
for line in open(sys.argv[2]):
    zap = line.strip()
    if not zap.startswith("~/"):
        continue
    for path in glob.glob(os.path.join(glob.escape(home), zap[2:])):
        parent = os.path.realpath(os.path.dirname(path))
        if parent != home and not parent.startswith(home + os.sep):
            continue
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.unlink(path)
PY
# What is left: any product file or folder, and any file that still names it.
(cd "$E2E_HOME" && find . -mindepth 1 2>/dev/null | sort) > "$H/after-zap-files.txt"
python3 - "$E2E_HOME" > "$H/residue.txt" 2>&1 <<'PY'
import os, sys
home = sys.argv[1]
for root, dirs, files in os.walk(home):
    for name in dirs + files:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, home)
        low = rel.lower()
        if any(word in low for word in ("hippocampus", "/mci", "mci/", "mci.sqlite")) or low in (".mci", "mci"):
            print("PATH", rel)
        elif low.endswith(".ses"):
            print("PATH", rel + " (a telemetry session file the OCR worker's ONNX Runtime wrote)")
    for name in files:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, home)
        if rel.startswith((".claude/projects", ".codex/sessions")):
            continue  # the synthetic Claude Code and Codex transcripts (their apps' data)
        try:
            data = open(path, "rb").read()
        except OSError:
            continue
        if b"mci-agent" in data or b"ai.hippocampus" in data or b"hippocampus" in data.lower():
            print("NAMES", rel)
PY
if [[ ! -s "$H/residue.txt" ]]; then
    pass e3 "after the cask's zap list nothing of Hippocampus is left in the home"
else
    fail e3 "left after uninstall (zap) and disconnect: $(sed 's/^PATH /path: /; s/^NAMES /mentions Hippocampus: /' "$H/residue.txt" | tr '\n' ';' | cut -c1-400)"
fi
person e4 "The database key stays in the login Keychain as ai.hippocampus.brain after uninstall (docs/GUIDE.md); this run used a file key, so removing it in Keychain Access needs a person"

# ---- Steps only a person can do ---------------------------------------------------
section "Needs a person"
person p1 "Reading a real screen: Screen Recording and Accessibility granted to this build, then scripts/run-live-capture-overlap.sh --app <app> (never granted by a script)"
person p2 "Shift twice and ⌃⇧Space opening Ask over another app, on a real keyboard with Accessibility allowed"
person p3 "Setup's permission screens, Stop Sharing, Pause and the menu-bar picture on a fresh macOS account"

# ---- Summary -------------------------------------------------------------------------
rm -f "$H/.sampling"
[[ -z "$SAMPLER_PID" ]] || wait "$SAMPLER_PID" 2>/dev/null
SAMPLER_PID=""
if [[ -f "$H/sampler-uninstall/summary.json" ]]; then
    late_sockets="$(json_field 'v["internet_sockets_seen"]' < "$H/sampler-uninstall/summary.json")"
    [[ "$late_sockets" == "0" ]] && pass net.late "no internet socket from the run's processes during uninstall ($(json_field 'v["samples"]' < "$H/sampler-uninstall/summary.json") samples)" \
        || fail net.late "$late_sockets internet socket(s) during uninstall: see sampler-uninstall/net.log"
fi
printf '\n== Summary: %d PASS, %d FAIL, %d SKIP, %d PERSON (%ds)\n' \
    "$STATUS_PASS" "$STATUS_FAIL" "$STATUS_SKIP" "$STATUS_PERSON" "$(( $(date +%s) - START_EPOCH ))"
(( STATUS_FAIL == 0 ))
