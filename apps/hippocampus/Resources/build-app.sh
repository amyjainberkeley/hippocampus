#!/usr/bin/env bash
set -euo pipefail

# build-app.sh — Assemble Hippocampus.app bundle from pre-built binaries.
#
# This script bridges SwiftPM (which only builds the Hippocampus
# executable) with a working .app bundle (binaries copied in, Info.plist,
# codesigned). Release assembly requires a stable Developer ID identity.
# Ad-hoc signing is available only for an explicitly requested debug build.
#
# Prerequisites:
#   1. scripts/swift-package.sh build -c release --package-path apps/hippocampus
#   2. scripts/swift-package.sh build -c release --package-path adapters/macos/MCICaptureHelper
#   3. scripts/swift-package.sh build -c release --package-path apps/recall-ui
#   4. cargo build --workspace --release
#
# Usage:
#   ./build-app.sh [--help] [--debug] [--development-ad-hoc]
#                  [--development-lite] [--dist DIR]
#
# Dev iteration loop:
#   1. Make changes to Sources/
#   2. scripts/swift-package.sh build --package-path apps/hippocampus
#   3. ./Resources/build-app.sh --debug   (assembles from .build/debug/)
#   4. open dist/Hippocampus.app          (test from Spotlight / Finder)
#   5. To test release, use the prerequisite commands above, then run this script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd)"

PROFILE="release"
DEVELOPMENT_ADHOC=0
DEVELOPMENT_LITE=0
CURRENT_SOURCE_QUALIFICATION=0
EXPECTED_QUALIFICATION_TEAM_ID="BV6KGKFKP4"
DIST_DIR="$PKG_DIR/dist"
CHANGELOG_SRC="$REPO_ROOT/CHANGELOG.md"
NOTICE_SRC="$REPO_ROOT/NOTICE"
TOML_LICENSE_VERIFIER="$REPO_ROOT/scripts/verify-toml-license-contract.py"
STATUS_SRC="$REPO_ROOT/docs/STATUS.md"
MODELS_MANIFEST_SRC="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/Resources/models.json"
KEYCHAIN_CONTRACT_SRC="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/Resources/keychain-sharing-contract.json"
APP_GROUP_CONTRACT="$REPO_ROOT/scripts/lib/app-group-contract.sh"
PRODUCT_SOURCE_DIGEST_TOOL="$REPO_ROOT/scripts/product-source-digest.py"
BUILD_PROVENANCE_TOOL="$REPO_ROOT/scripts/build-provenance.py"
STATUS_AUDIT_MAX_COMMITS=3

fatal() {
    echo "FATAL: $1"
    shift
    while [[ $# -gt 0 ]]; do
        echo "       $1"
        shift
    done
    exit 1
}

if [[ ! -f "$APP_GROUP_CONTRACT" ]]; then
    fatal "App Group contract helper missing at $APP_GROUP_CONTRACT"
fi
# shellcheck source=/dev/null
source "$APP_GROUP_CONTRACT"

validate_changelog_release() {
    local version="$1"

    if ! python3 - "$CHANGELOG_SRC" "$version" <<'PY'
import re
import sys

path, wanted_version = sys.argv[1:]
header = re.compile(r"^## \[([^]]+)\]")
found_release = False
in_release = False
in_section = False
has_item = False

with open(path, encoding="utf-8") as changelog:
    for raw_line in changelog:
        line = raw_line.strip()
        match = header.match(line)
        if match:
            if in_release:
                break
            in_release = match.group(1).casefold() == wanted_version.casefold()
            found_release = found_release or in_release
            in_section = False
            continue
        if not in_release:
            continue
        if line.startswith("### "):
            in_section = True
            continue
        if in_section and (line.startswith("- ") or line.startswith("* ")):
            if line[2:].strip():
                has_item = True
                break

sys.exit(0 if found_release and has_item else 1)
PY
    then
        fatal \
            "CHANGELOG.md has no nonempty $version release" \
            "Add a curated ## [$version] section with at least one section and user-facing bullet." \
            "Refusing to ship a bundle that opens What's New to an empty state."
    fi
}

validate_status_audit() {
    if [[ ! -f "$STATUS_SRC" ]]; then
        fatal \
            "docs/STATUS.md missing at $STATUS_SRC" \
            "Restore the canonical release-status document before building."
    fi

    local audit_sha
    audit_sha=$(sed -nE 's/^Audited code baseline: `([0-9a-fA-F]{7,40})`.*$/\1/p' "$STATUS_SRC" | head -1)
    if [[ -z "$audit_sha" ]]; then
        fatal \
            "docs/STATUS.md has no audited code baseline SHA" \
            'Add: Audited code baseline: `<git-sha>`'
    fi

    if ! git -C "$REPO_ROOT" rev-parse --verify "$audit_sha^{commit}" >/dev/null 2>&1; then
        fatal \
            "docs/STATUS.md audit baseline does not exist: $audit_sha" \
            "Stamp STATUS.md against a commit available in this clone."
    fi

    if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$audit_sha" HEAD; then
        fatal \
            "docs/STATUS.md audit baseline is not an ancestor of HEAD" \
            "Recorded baseline: $audit_sha" \
            "Refresh STATUS.md against the current branch before building."
    fi

    local audit_distance
    audit_distance=$(git -C "$REPO_ROOT" rev-list --count "$audit_sha"..HEAD)
    if (( audit_distance > STATUS_AUDIT_MAX_COMMITS )); then
        fatal \
            "docs/STATUS.md audit baseline is $audit_distance commits behind HEAD; maximum is $STATUS_AUDIT_MAX_COMMITS" \
            "Refresh the status claims and stamp the immediate pre-documentation code baseline."
    fi

    echo "  docs/STATUS.md audit baseline OK ($audit_sha, $audit_distance commit(s) behind HEAD)"
}

usage() {
    echo "Usage: build-app.sh [OPTIONS]"
    echo ""
    echo "Assemble Hippocampus.app from pre-built binaries."
    echo ""
    echo "Options:"
    echo "  --debug     Use debug builds instead of release"
    echo "  --development-ad-hoc  Allow unstable ad-hoc signing with --debug only"
    echo "  --development-lite  Omit unavailable Core ML models for local UI verification"
    echo "  --current-source-qualification  Rebuild every executable before a signed debug qualification"
    echo "  --dist DIR  Output directory (default: apps/hippocampus/dist/)"
    echo "  --help      Show this help"
    echo ""
    echo "Prerequisites:"
    echo "  scripts/swift-package.sh build -c release --package-path apps/hippocampus"
    echo "  scripts/swift-package.sh build -c release --package-path adapters/macos/MCICaptureHelper"
    echo "  scripts/swift-package.sh build -c release --package-path apps/recall-ui"
    echo "  cargo build --workspace --release"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) PROFILE="debug"; shift ;;
        --development-ad-hoc) DEVELOPMENT_ADHOC=1; shift ;;
        --development-lite) DEVELOPMENT_LITE=1; shift ;;
        --current-source-qualification) CURRENT_SOURCE_QUALIFICATION=1; shift ;;
        --dist) DIST_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ "$DEVELOPMENT_LITE" -eq 1 && "$PROFILE" != "debug" ]]; then
    fatal \
        "development-lite requires --debug" \
        "Release assembly keeps every model-completeness gate enabled."
fi
if [[ "$DEVELOPMENT_LITE" -eq 1 && "$DEVELOPMENT_ADHOC" -ne 1 ]]; then
    fatal \
        "development-lite requires --development-ad-hoc" \
        "A model-incomplete bundle must remain an explicitly disposable local artifact."
fi
if [[ "$CURRENT_SOURCE_QUALIFICATION" -eq 1 && "$PROFILE" != "debug" ]]; then
    fatal \
        "current-source qualification requires --debug" \
        "Release builds use the normal release pipeline and its separate artifact gates."
fi
if [[ "$CURRENT_SOURCE_QUALIFICATION" -eq 1 && "$DEVELOPMENT_ADHOC" -eq 1 ]]; then
    fatal \
        "current-source qualification requires Developer ID signing" \
        "Do not combine --current-source-qualification with --development-ad-hoc."
fi

APP="$DIST_DIR/Hippocampus.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Locate binaries
HIPPOCAMPUS_BIN="$PKG_DIR/.build/$PROFILE/Hippocampus"
HELPER_BIN="$REPO_ROOT/adapters/macos/MCICaptureHelper/.build/$PROFILE/mci-capture-helper"
AGENT_BIN="$REPO_ROOT/target/$PROFILE/mci-agent"
RECALL_UI_BIN="$REPO_ROOT/apps/recall-ui/.build/$PROFILE/recall-ui"
ONBOARDING_BIN="$REPO_ROOT/apps/onboarding/.build/$PROFILE/onboarding"
NATIVE_HOST_BIN="$REPO_ROOT/target/$PROFILE/hippocampus-native-host"
KNOWN_SAFE="$REPO_ROOT/adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml"
APP_ICON="$REPO_ROOT/assets/branding/AppIcon.icns"
INFO_PLIST="$SCRIPT_DIR/Info.plist"

# SwiftPM emits {Package}_{Target}.bundle next to the executable for any
# target that declares `resources:` in Package.swift, plus an auto-
# generated `resource_bundle_accessor.swift` that exposes `Bundle.module`.
# The Swift 6.3 accessor checks exactly two paths:
#
#   1. Bundle.main.bundleURL.appendingPathComponent(<name>.bundle)
#      For an .app, Bundle.main.bundleURL IS the .app directory itself,
#      so this resolves to <.app>/Hippocampus_HippocampusKit.bundle —
#      the TOP LEVEL of the bundle, NOT Contents/Resources/. codesign
#      rejects any content (directory OR symlink) at the .app root with
#      "unsealed contents present in the bundle root", so we cannot
#      satisfy this lookup on a Developer-ID-signed build.
#   2. A compile-time absolute fallback to .build/<arch>/release/<name>.bundle
#      that exists on the build host but not on end-user machines.
#
# Cycle 8.16 (DMG 8d4dfc22…) crashed on launch on every end-user machine
# because both lookups missed. Cycle 8.15 (3fdbc52a…) and earlier appeared
# to work only because the dev-build fallback path happened to exist on
# the CEO's primary checkout (`/Users/ao/Documents/GitHub/mci/...`). The
# /tmp/dmg-reship-cycle-8.16 worktree was deleted post-build, exposing
# the latent crash.
#
# Cycle 8.17 fix has two halves:
#   (a) ModelDownloadManager + AllowlistTOMLLoader: swap resolver order
#       so Bundle.main (Contents/Resources/) is queried BEFORE Bundle.module.
#       Accessing Bundle.module triggers the SwiftPM accessor's static-let
#       init which fatalError's when both lookups miss — the prior Bundle.main
#       fallback at line 60 was dead code.
#   (b) This script copies the real `models.json` and `known-safe-apps.toml`
#       directly into Contents/Resources/ alongside the SwiftPM resource
#       bundle. Bundle.main.url(forResource:withExtension:) reads from
#       Contents/Resources/ for an .app, so the resolver-order swap above
#       finds the file via the macOS-conventional path and never touches
#       Bundle.module on a production install. The Contents/Resources/
#       `Hippocampus_HippocampusKit.bundle` directory is retained as a
#       defense-in-depth for any future Bundle.module access via the
#       SwiftPM accessor's (now non-load-bearing) fallback path.
HIPPOCAMPUS_KIT_BUNDLE="$PKG_DIR/.build/$PROFILE/Hippocampus_HippocampusKit.bundle"

FRAMEWORKS="$CONTENTS/Frameworks"

# Locate Sparkle.framework from SwiftPM build artifacts
SPARKLE_FRAMEWORK=""
for candidate in \
    "$PKG_DIR/.build/$PROFILE/Sparkle.framework" \
    "$PKG_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.framework" \
    "$PKG_DIR/.build/artifacts/Sparkle/Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then
        SPARKLE_FRAMEWORK="$candidate"
        break
    fi
done

# --- Detect Developer ID signing identity ---

if [[ -z "${DEVELOPER_ID:-}" ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning | \
        grep "Developer ID Application" | \
        head -1 | \
        sed 's/.*"\(.*\)"/\1/' || true)
fi

if [[ "$PROFILE" == "debug" && "$DEVELOPMENT_ADHOC" -eq 1 ]]; then
    SIGNING_MODE="ad-hoc"
elif [[ -n "$DEVELOPER_ID" ]]; then
    SIGNING_MODE="developer-id"
elif [[ "$DEVELOPMENT_ADHOC" -eq 1 ]]; then
    fatal \
        "Ad-hoc signing is development-only and requires --debug" \
        "Release assembly requires a stable Developer ID Application identity."
else
    fatal \
        "Release assembly requires a stable Developer ID Application identity" \
        "Install/select a Developer ID Application certificate, or use --debug --development-ad-hoc for a disposable local build." \
        "Ad-hoc rebuilds do not preserve the file-Keychain SecAccess ACL across versions."
fi

if ! APP_GROUP_ID=$(hippocampus_resolve_app_group_id "$SIGNING_MODE" "$DEVELOPER_ID"); then
    fatal \
        "Unable to resolve the macOS App Group identity" \
        "Developer ID builds must use one Team-ID-prefixed group shared by the app and Safari extension."
fi
if [[ "$CURRENT_SOURCE_QUALIFICATION" -eq 1 ]] \
    && [[ "${APP_GROUP_ID%%.*}" != "$EXPECTED_QUALIFICATION_TEAM_ID" ]]; then
    fatal \
        "current-source qualification identity does not match the production Team ID" \
        "Expected: $EXPECTED_QUALIFICATION_TEAM_ID" \
        "Resolved: ${APP_GROUP_ID%%.*}"
fi
SIGNING_SCRATCH=$(mktemp -d -t hippocampus-signing)
trap 'rm -rf "$SIGNING_SCRATCH"' EXIT
ENTITLEMENTS_SOURCE="$SCRIPT_DIR/Hippocampus.entitlements"
ENTITLEMENTS="$SIGNING_SCRATCH/Hippocampus.entitlements"
CAPTURE_HELPER_ENTITLEMENTS="$SCRIPT_DIR/MCICaptureHelper.entitlements"
hippocampus_render_app_group_entitlements \
    "$ENTITLEMENTS_SOURCE" "$ENTITLEMENTS" "$APP_GROUP_ID"

echo "=== Hippocampus.app assembly ==="
echo "Profile:   $PROFILE"
echo "Signing:   $SIGNING_MODE"
if [[ "$DEVELOPMENT_LITE" -eq 1 ]]; then
    echo "Models:    development-lite (missing models stay visibly unavailable)"
fi
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    echo "Identity:  $DEVELOPER_ID"
fi
echo "App Group: $APP_GROUP_ID"
echo "Output:    $APP"
echo ""

if [[ "$CURRENT_SOURCE_QUALIFICATION" -eq 1 ]]; then
    echo "Rebuilding every shipped executable from the current checkout..."
    "$REPO_ROOT/scripts/swift-package.sh" build --package-path "$PKG_DIR"
    "$REPO_ROOT/scripts/swift-package.sh" build \
        --package-path "$REPO_ROOT/adapters/macos/MCICaptureHelper"
    "$REPO_ROOT/scripts/swift-package.sh" build \
        --package-path "$REPO_ROOT/apps/recall-ui"
    "$REPO_ROOT/scripts/swift-package.sh" build \
        --package-path "$REPO_ROOT/apps/onboarding"
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" \
        -p mci-agent --bins -p hippocampus-native-host
fi

# Verify binaries exist
for bin_path in "$HIPPOCAMPUS_BIN" "$HELPER_BIN" "$AGENT_BIN" "$RECALL_UI_BIN" "$ONBOARDING_BIN" "$NATIVE_HOST_BIN"; do
    if [[ ! -f "$bin_path" ]]; then
        echo "ERROR: Missing binary: $bin_path"
        echo "Run the prerequisite builds first. See --help."
        exit 1
    fi
done

if [[ ! -f "$CHANGELOG_SRC" ]]; then
    fatal \
        "CHANGELOG.md missing at $CHANGELOG_SRC" \
        "Run: ./scripts/gen-changelog.sh --output CHANGELOG.md" \
        "Refusing to ship a bundle whose What's New release notes have no committed source."
fi

if [[ ! -f "$NOTICE_SRC" ]]; then
    fatal \
        "NOTICE missing at $NOTICE_SRC" \
        "Restore the committed third-party and model attribution before building."
fi

echo "Verifying pinned TOML dependency licenses..."
python3 "$TOML_LICENSE_VERIFIER" --repo-root "$REPO_ROOT"

BUNDLE_SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)
if [[ -z "$BUNDLE_SHORT_VERSION" ]]; then
    fatal \
        "CFBundleShortVersionString missing from $INFO_PLIST" \
        "Refusing to validate What's New against an unknown bundle version."
fi
validate_changelog_release "$BUNDLE_SHORT_VERSION"
validate_status_audit

if [[ ! -f "$MODELS_MANIFEST_SRC" ]]; then
    fatal \
        "models.json missing at $MODELS_MANIFEST_SRC" \
        "Run: git restore apps/hippocampus/Sources/HippocampusKit/Resources/models.json" \
        "Refusing to guess model inputs without the committed manifest."
fi

if [[ ! -f "$KEYCHAIN_CONTRACT_SRC" ]]; then
    fatal \
        "Keychain sharing contract missing at $KEYCHAIN_CONTRACT_SRC" \
        "Restore the committed file-Keychain ACL contract before building."
fi

# Clean and create structure
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# Copy binaries
cp "$HIPPOCAMPUS_BIN" "$MACOS/Hippocampus"
cp "$HELPER_BIN" "$MACOS/MCICaptureHelper"
cp "$AGENT_BIN" "$MACOS/mci-agent"
cp "$RECALL_UI_BIN" "$MACOS/recall-ui"
cp "$ONBOARDING_BIN" "$MACOS/onboarding"
cp "$NATIVE_HOST_BIN" "$MACOS/hippocampus-native-host"

# Embed verified offline OCR before sealing app provenance. Release and debug
# app bundles must be self-contained; only an unbundled helper uses Vision.
OCR_SIGNING_IDENTITY="$DEVELOPER_ID"
if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then OCR_SIGNING_IDENTITY="-"; fi
python3 "$REPO_ROOT/tools/ocr/bundle.py" \
    --destination "$RESOURCES/HippocampusOCR" \
    --identity "$OCR_SIGNING_IDENTITY" \
    || fatal "Offline OCR worker is missing, stale, or could not be signed. See tools/ocr/README.md."

# Copy resources
cp "$INFO_PLIST" "$CONTENTS/Info.plist"
hippocampus_write_bundle_app_group_id "$CONTENTS/Info.plist" "$APP_GROUP_ID"
if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :MCIDevelopmentFileKeyEnabled bool true' \
        "$CONTENTS/Info.plist"
fi
if [[ -f "$KNOWN_SAFE" ]]; then
    cp "$KNOWN_SAFE" "$RESOURCES/known-safe-apps.toml"
fi
cp "$CHANGELOG_SRC" "$RESOURCES/CHANGELOG.md"
cp "$NOTICE_SRC" "$RESOURCES/NOTICE.txt"
cp "$MODELS_MANIFEST_SRC" "$RESOURCES/models.json"
cp "$KEYCHAIN_CONTRACT_SRC" "$RESOURCES/keychain-sharing-contract.json"
if [[ ! -x "$PRODUCT_SOURCE_DIGEST_TOOL" ]]; then
    fatal "product source digest tool missing at $PRODUCT_SOURCE_DIGEST_TOOL"
fi
if [[ ! -x "$BUILD_PROVENANCE_TOOL" ]]; then
    fatal "build provenance tool missing at $BUILD_PROVENANCE_TOOL"
fi
SOURCE_DIGEST="$(python3 "$PRODUCT_SOURCE_DIGEST_TOOL" --repo-root "$REPO_ROOT")" \
    || fatal "could not compute product source digest"
SOURCE_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)" \
    || fatal "could not resolve source HEAD"
write_build_provenance() {
    local provenance_args=(
        create
        --app "$APP"
        --source-head "$SOURCE_HEAD"
        --source-digest "$SOURCE_DIGEST"
    )
    if [[ "$CURRENT_SOURCE_QUALIFICATION" -eq 1 ]]; then
        provenance_args+=(--current-source-qualification)
    fi
    python3 "$BUILD_PROVENANCE_TOOL" "${provenance_args[@]}"
    echo "  build provenance bundled OK → $RESOURCES/build-provenance.json"
}
echo "  CHANGELOG.md bundled OK → $RESOURCES/CHANGELOG.md"
echo "  NOTICE.txt bundled OK → $RESOURCES/NOTICE.txt"
echo "  models.json bundled OK → $RESOURCES/models.json"

# Copy SwiftPM-generated resource bundle for HippocampusKit into
# Contents/Resources/ (macOS-conventional location; codesign seals it as
# part of the .app's signed-resource set). Bundle.module's primary lookup
# does NOT find it there for an .app wrapper, but Bundle.main can — and
# the resolver-order swap in ModelDownloadManager + AllowlistTOMLLoader
# (cycle 8.17) routes through Bundle.main first. We additionally copy
# `models.json` directly into Contents/Resources/ so
# Bundle.main.url(forResource: "models", withExtension: "json") returns
# a valid URL via the .app's standard resource search path.
KIT_BUNDLE_NAME="$(basename "$HIPPOCAMPUS_KIT_BUNDLE")"
if [[ -d "$HIPPOCAMPUS_KIT_BUNDLE" ]]; then
    ditto "$HIPPOCAMPUS_KIT_BUNDLE" "$RESOURCES/$KIT_BUNDLE_NAME"
else
    echo "ERROR: HippocampusKit resource bundle not found at $HIPPOCAMPUS_KIT_BUNDLE"
    echo "Run scripts/swift-package.sh build -c $PROFILE --package-path apps/hippocampus first."
    exit 1
fi
# AppIcon.icns — referenced by Info.plist's CFBundleIconFile key.
# Without this copy, Finder + Dock render the generic blank app icon.
if [[ -f "$APP_ICON" ]]; then
    cp "$APP_ICON" "$RESOURCES/AppIcon.icns"
else
    echo "WARNING: AppIcon.icns missing at $APP_ICON — Finder/Dock will show the generic blank icon."
fi

# Status-bar template icons — read at runtime by MenuBarIcon via
# Image("statusbar-icon").renderingMode(.template). macOS tints the
# alpha mask for light/dark menu bars; the source PNGs are black-on-
# transparent (see AppIcon-template.svg). Without these the menu bar
# shows nothing for the running/paused states.
STATUSBAR_PNG_DIR="$REPO_ROOT/assets/branding"
for sb in statusbar-icon.png statusbar-icon@2x.png statusbar-icon@3x.png; do
    if [[ -f "$STATUSBAR_PNG_DIR/$sb" ]]; then
        cp "$STATUSBAR_PNG_DIR/$sb" "$RESOURCES/$sb"
    else
        echo "ERROR: Missing $STATUSBAR_PNG_DIR/$sb — menu-bar icon will not render."
        exit 1
    fi
done

# Embed Sparkle.framework (ships pre-signed; we re-codesign the outer app).
#
# `ditto`, NOT `cp -R` — frameworks contain symlinks
# (`Sparkle.framework/Versions/Current → B`, `Sparkle.framework/Sparkle →
# Versions/Current/Sparkle`) that the framework's code-signature seal
# depends on. `cp -R` on macOS sometimes follows symlinks and duplicates
# trees, leaving the framework structurally valid on the build host but
# broken after the DMG round-trip — Gatekeeper rejects with "developer
# cannot be verified" on the user's Mac even when notary + staple both
# pass locally. Apple explicitly recommends `ditto` for frameworks
# (Apple devforum 128166).
if [[ -n "$SPARKLE_FRAMEWORK" && -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Embedding Sparkle.framework from: $SPARKLE_FRAMEWORK"
    rm -rf "$FRAMEWORKS/Sparkle.framework"
    ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
else
    echo "WARNING: Sparkle.framework not found. Auto-update will not work."
    echo "  Build with scripts/swift-package.sh build -c $PROFILE --package-path apps/hippocampus first."
fi

# Add @executable_path/../Frameworks to rpath so dyld finds Sparkle.framework.
# SwiftPM does not add this automatically; must be set before codesigning.
if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
    if ! otool -l "$MACOS/Hippocampus" | grep -A 2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
        echo "Adding @executable_path/../Frameworks rpath to Hippocampus binary..."
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Hippocampus"
    fi
fi

# Embed ArcticEmbedS Core ML model (per ADR-0011 + ADR-0028 §4).
# The .mlpackage is produced offline by scripts/convert_embedder.py
# and committed locally (gitignored — too big to checkin).
EMBEDDER_PACKAGE="$REPO_ROOT/models/ArcticEmbedS_FP16.mlpackage"
EMBEDDER_COMPILED="$REPO_ROOT/models/ArcticEmbedS_FP16.mlmodelc"
EMBEDDER_DEST_DIR="$RESOURCES/Models"
EMBEDDER_DEST="$EMBEDDER_DEST_DIR/ArcticEmbedS_FP16.mlmodelc"
EMBEDDER_SOURCE_PRESENT=0

if [[ -d "$EMBEDDER_COMPILED" ]]; then
    echo "Bundling pre-compiled ArcticEmbedS_FP16.mlmodelc"
    EMBEDDER_SOURCE_PRESENT=1
    mkdir -p "$EMBEDDER_DEST_DIR"
    rm -rf "$EMBEDDER_DEST"
    cp -R "$EMBEDDER_COMPILED" "$EMBEDDER_DEST_DIR/"
elif [[ -d "$EMBEDDER_PACKAGE" ]]; then
    echo "Compiling ArcticEmbedS_FP16.mlpackage → .mlmodelc"
    EMBEDDER_SOURCE_PRESENT=1
    mkdir -p "$EMBEDDER_DEST_DIR"
    rm -rf "$EMBEDDER_DEST"
    xcrun coremlcompiler compile "$EMBEDDER_PACKAGE" "$EMBEDDER_DEST_DIR"
elif [[ "$DEVELOPMENT_LITE" -eq 1 ]]; then
    echo "DEVELOPMENT LITE: ArcticEmbedS is unavailable; recall stays lexical-only."
else
    fatal \
        "ArcticEmbedS_FP16.{mlpackage,mlmodelc} missing under $REPO_ROOT/models" \
        "Run: pip install -r scripts/requirements-ml.txt" \
        "Then: python scripts/convert_embedder.py --output models/ArcticEmbedS_FP16.mlpackage --verify" \
        "Refusing to ship a bundle whose semantic recall silently degrades to lexical-only."
fi

if [[ "$EMBEDDER_SOURCE_PRESENT" -eq 1 ]]; then
    if [[ ! -d "$EMBEDDER_DEST" ]]; then
        fatal \
            "ArcticEmbedS_FP16.mlmodelc missing at $EMBEDDER_DEST after bundling" \
            "Run: python scripts/convert_embedder.py --output models/ArcticEmbedS_FP16.mlpackage --verify" \
            "Then re-run: ./apps/hippocampus/Resources/build-app.sh"
    fi
    if [[ ! -f "$EMBEDDER_DEST/model.mil" || ! -d "$EMBEDDER_DEST/weights" || ! -f "$EMBEDDER_DEST/coremldata.bin" ]]; then
        fatal \
            "bundled $EMBEDDER_DEST is structurally incomplete" \
            "(missing model.mil, weights/, or coremldata.bin)." \
            "Rebuild with: python scripts/convert_embedder.py --output models/ArcticEmbedS_FP16.mlpackage --verify"
    fi
fi

# Embed bert-base-NER Core ML model (V2-P5+ sync NER tier; CEO-ratified
# 2026-06-04 — see project-gliner-variant-pin / PR #297). Mirrors the
# ArcticEmbedS embedder block above exactly. The .mlpackage is produced
# offline by the conversion env and committed locally (gitignored — the
# compiled .mlmodelc is ~103 MB; that bundle bloat is expected and accepted
# per the CEO "best option" directive). load_ner_sync_backend() in mci-agent
# resolves Contents/Resources/Models/bert_base_NER_INT8.mlmodelc BEFORE its
# dev fallback, so an INSTALLED app loads THIS bundled copy.
NER_PACKAGE="$REPO_ROOT/models/bert_base_NER_INT8.mlpackage"
NER_COMPILED="$REPO_ROOT/models/bert_base_NER_INT8.mlmodelc"
NER_DEST_DIR="$RESOURCES/Models"
NER_DEST="$NER_DEST_DIR/bert_base_NER_INT8.mlmodelc"
NER_SOURCE_PRESENT=0

if [[ -d "$NER_COMPILED" ]]; then
    echo "Bundling pre-compiled bert_base_NER_INT8.mlmodelc"
    NER_SOURCE_PRESENT=1
    mkdir -p "$NER_DEST_DIR"
    # rm -rf first so a rebuild REPLACES the model rather than merging into a
    # stale .mlmodelc. `cp -R src dest/` merges into a pre-existing dest dir,
    # which on a model-version swap could leave orphaned shards from the old
    # model that still pass the structural gate below but fail at load.
    rm -rf "$NER_DEST"
    cp -R "$NER_COMPILED" "$NER_DEST_DIR/"
elif [[ -d "$NER_PACKAGE" ]]; then
    echo "Compiling bert_base_NER_INT8.mlpackage → .mlmodelc"
    NER_SOURCE_PRESENT=1
    mkdir -p "$NER_DEST_DIR"
    rm -rf "$NER_DEST"
    xcrun coremlcompiler compile "$NER_PACKAGE" "$NER_DEST_DIR"
else
    echo "BERT NER is unavailable; Tier 1 entity extraction remains active."
fi

# Fail-loud NER-model gate — FATAL.
# Codified-WARNs-are-stops discipline (cycle 8.25 — see
# feedback-codified-warns-are-stops). A matching NER completeness gate is
# mirrored into build-installer.sh (next to the embedder gate) so the
# `build-installer.sh --skip-build` path — which bypasses this script — also
# trips it, exactly as the embedder completeness gate does. If we attempted
# the copy/compile above, the compiled model MUST be present in the bundle
# afterward. A silent cp/coremlcompiler failure here is exactly the cycle-8.24
# class of regression that shipped a broken bundle clean through codesign +
# notarization (nothing in the signing/notary path inspects resource
# completeness). Refuse to continue so the operator fixes it and re-runs from
# scratch instead of shipping an installed app whose NER tier silently
# disables (or, on a dev checkout, masks the gap via the ~/Documents dev path).
if [[ "$NER_SOURCE_PRESENT" -eq 1 ]]; then
    if [[ ! -d "$NER_DEST" ]]; then
        echo "FATAL: bert_base_NER_INT8.mlmodelc missing at:"
        echo "         $NER_DEST"
        echo "       after attempting to bundle it from the source model."
        echo "       Refusing to ship a bundle whose sync NER tier would silently"
        echo "       disable on an installed app."
        exit 1
    fi
    # Structural sanity: a compiled .mlmodelc must carry its MIL program
    # (model.mil), its compiled model description (coremldata.bin — read first
    # by MLModel at load), and its weight blob (weights/, ~108 MB for this
    # model). A truncated/partial copy passes the directory-exists check but
    # fails NerTier2Backend::load at runtime; checking all three catches the
    # realistic interrupted-copy failure mode.
    if [[ ! -f "$NER_DEST/model.mil" || ! -d "$NER_DEST/weights" || ! -f "$NER_DEST/coremldata.bin" ]]; then
        echo "FATAL: bundled $NER_DEST is structurally incomplete"
        echo "       (missing model.mil, weights/, or coremldata.bin). Refusing to ship."
        exit 1
    fi
    echo "  bert-base-NER bundled OK → $NER_DEST"
fi

# --- Optional Qwen3-1.7B-FP16 Core ML prose model ---
# Evidence-cited extractive briefs are the zero-download default. Custom builds
# may include Qwen source artifacts; when present, validate and bundle the
# model with its tokenizer as an optional wording upgrade.
QWEN3_MODEL_ID="qwen3-1.7b-fp16"
QWEN3_BASENAME="Qwen3-1.7B-FP16.mlmodelc"
QWEN3_PACKAGE="$REPO_ROOT/models/Qwen3-1.7B-FP16.mlpackage"
QWEN3_COMPILED="$REPO_ROOT/models/$QWEN3_BASENAME"
QWEN3_TOKENIZER="$REPO_ROOT/models/tokenizer.json"
QWEN3_DEST_DIR="$RESOURCES/Models/$QWEN3_MODEL_ID"
QWEN3_DEST="$QWEN3_DEST_DIR/$QWEN3_BASENAME"
QWEN3_TOKENIZER_DEST="$QWEN3_DEST_DIR/tokenizer.json"
QWEN3_SOURCE_PRESENT=0
if [[ -d "$QWEN3_COMPILED" ]]; then
    echo "Bundling pre-compiled $QWEN3_BASENAME (~3.4 GB — this may take ~30s)"
    QWEN3_SOURCE_PRESENT=1
    mkdir -p "$QWEN3_DEST_DIR"
    rm -rf "$QWEN3_DEST"
    cp -R "$QWEN3_COMPILED" "$QWEN3_DEST_DIR/"
elif [[ -d "$QWEN3_PACKAGE" ]]; then
    echo "Compiling $QWEN3_BASENAME from .mlpackage"
    QWEN3_SOURCE_PRESENT=1
    mkdir -p "$QWEN3_DEST_DIR"
    rm -rf "$QWEN3_DEST"
    xcrun coremlcompiler compile "$QWEN3_PACKAGE" "$QWEN3_DEST_DIR"
else
    echo "Qwen3 is unavailable; evidence-cited extractive briefs remain active."
fi

# A custom build that provides Qwen must provide one complete, runnable unit.
if [[ "$QWEN3_SOURCE_PRESENT" -eq 1 ]]; then
    if [[ ! -f "$QWEN3_TOKENIZER" ]]; then
        fatal \
            "Qwen tokenizer.json missing at $QWEN3_TOKENIZER" \
            "Run: python scripts/convert_brief_model.py --output models/Qwen3-1.7B-FP16.mlpackage --verify" \
            "The optional Qwen model is present but cannot run without its tokenizer."
    fi
    if [[ ! -d "$QWEN3_DEST" ]]; then
        echo "FATAL: $QWEN3_BASENAME missing at:"
        echo "         $QWEN3_DEST"
        echo "       after attempting to bundle it from the source model."
        echo "       Refusing to advertise a richer prose model that cannot run."
        exit 1
    fi
    # Structural sanity: same .mlmodelc invariants as NER — model.mil,
    # weights/, coremldata.bin. Weights blob is ~3.4 GB for Qwen3-1.7B FP16.
    if [[ ! -f "$QWEN3_DEST/model.mil" || ! -d "$QWEN3_DEST/weights" || ! -f "$QWEN3_DEST/coremldata.bin" ]]; then
        echo "FATAL: bundled $QWEN3_DEST is structurally incomplete"
        echo "       (missing model.mil, weights/, or coremldata.bin). Refusing to ship."
        exit 1
    fi
    cp "$QWEN3_TOKENIZER" "$QWEN3_TOKENIZER_DEST"
    if ! python3 - "$QWEN3_TOKENIZER_DEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
if not isinstance(payload, dict) or not payload:
    raise SystemExit("tokenizer.json must be a nonempty JSON object")
PY
    then
        fatal \
            "bundled Qwen tokenizer is invalid at $QWEN3_TOKENIZER_DEST" \
            "Re-run scripts/convert_brief_model.py from the pinned model revision."
    fi
    echo "  Qwen3-1.7B bundled OK → $QWEN3_DEST"
fi

# --- Bundle the Chromium extension as a load-unpacked dir ---
#
# The Chrome / Arc / Brave / Edge extension at extensions/chromium/ is
# not in the Web Store yet (DOGFOOD_V1 #16). For dogfood v1 we ship
# the unpacked dir inside the .app so onboarding's "Install" button
# can reveal it in Finder and the user can drag-drop it onto Chrome's
# chrome://extensions page. When the Web Store / .crx path lands,
# this block becomes redundant.
CHROMIUM_EXT_SRC="$REPO_ROOT/extensions/chromium"
CHROMIUM_EXT_DEST="$RESOURCES/Extensions/Chromium"
if [[ -d "$CHROMIUM_EXT_SRC" ]]; then
    echo "Bundling Chromium extension (unpacked, Load-Unpacked flow)"
    rm -rf "$CHROMIUM_EXT_DEST"
    mkdir -p "$CHROMIUM_EXT_DEST"
    # Copy only the files Chrome actually needs — skip __tests__,
    # node_modules, package.json, hidden files.
    #
    # The native-messaging host manifest JSON is NOT copied here. It is
    # NOT part of the loaded extension; Chromium reads it from a
    # per-browser NativeMessagingHosts/ directory under
    # ~/Library/Application Support/<browser>/. Hippocampus writes it
    # from `BrowserHostInstaller` at app launch with the resolved
    # binary path + deterministic extension ID.
    for entry in manifest.json background.js content.js icons; do
        src="$CHROMIUM_EXT_SRC/$entry"
        if [[ -e "$src" ]]; then
            cp -R "$src" "$CHROMIUM_EXT_DEST/"
        fi
    done
fi

# --- Safari Web Extension .appex ---

SAFARI_EXT_DIR="$REPO_ROOT/extensions/safari"
APPEX_SRC="$SAFARI_EXT_DIR/appex"
APPEX_HANDLER="$APPEX_SRC/SafariWebExtensionHandler.swift"
APPEX_PLIST="$APPEX_SRC/Info.plist"
APPEX_ENTITLEMENTS_SOURCE="$APPEX_SRC/HippocampusSafariExtension.entitlements"
APPEX_ENTITLEMENTS="$SIGNING_SCRATCH/HippocampusSafariExtension.entitlements"
hippocampus_render_app_group_entitlements \
    "$APPEX_ENTITLEMENTS_SOURCE" "$APPEX_ENTITLEMENTS" "$APP_GROUP_ID"

PLUGINS="$CONTENTS/PlugIns"
APPEX_BUNDLE="$PLUGINS/HippocampusSafariExtension.appex"
APPEX_CONTENTS="$APPEX_BUNDLE/Contents"
APPEX_MACOS="$APPEX_CONTENTS/MacOS"
APPEX_RESOURCES="$APPEX_CONTENTS/Resources"

if [[ -f "$APPEX_HANDLER" ]]; then
    echo ""
    echo "=== Safari Web Extension (.appex) ==="
    mkdir -p "$APPEX_MACOS" "$APPEX_RESOURCES"

    echo "Compiling SafariWebExtensionHandler..."
    swiftc \
        -sdk "$(xcrun --show-sdk-path)" \
        -target "$(uname -m)-apple-macos14.0" \
        -framework Foundation \
        -framework SafariServices \
        -module-name HippocampusSafariExtension \
        -emit-executable \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -o "$APPEX_MACOS/HippocampusSafariExtension" \
        "$APPEX_HANDLER"

    cp "$APPEX_PLIST" "$APPEX_CONTENTS/Info.plist"
    hippocampus_write_bundle_app_group_id \
        "$APPEX_CONTENTS/Info.plist" "$APP_GROUP_ID"

    for f in manifest.json background.js content.js; do
        if [[ -f "$SAFARI_EXT_DIR/$f" ]]; then
            cp "$SAFARI_EXT_DIR/$f" "$APPEX_RESOURCES/$f"
        fi
    done

    # Toolbar icon set (referenced by manifest action.default_icon).
    # Regenerate with scripts/generate-extension-toolbar-icons.py.
    if [[ -d "$SAFARI_EXT_DIR/icons" ]]; then
        mkdir -p "$APPEX_RESOURCES/icons"
        cp "$SAFARI_EXT_DIR/icons"/*.png "$APPEX_RESOURCES/icons/"
    fi

    echo "  .appex assembled at $APPEX_BUNDLE"
else
    echo ""
    echo "WARNING: Safari extension handler not found at $APPEX_HANDLER"
    echo "  Skipping .appex build. Safari extension will not be available."
fi

echo ""
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    echo "Codesigning with Developer ID (hardened runtime)..."

    # Inside-out order: sign innermost first.
    if [[ -d "$APPEX_BUNDLE" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            --entitlements "$APPEX_ENTITLEMENTS" \
            "$APPEX_BUNDLE"
    fi

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$CAPTURE_HELPER_ENTITLEMENTS" \
        "$MACOS/MCICaptureHelper"

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        "$MACOS/mci-agent"

    if [[ -f "$MACOS/recall-ui" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            "$MACOS/recall-ui"
    fi

    if [[ -f "$MACOS/onboarding" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            "$MACOS/onboarding"
    fi

    if [[ -f "$MACOS/hippocampus-native-host" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            "$MACOS/hippocampus-native-host"
    fi

    # Sign Sparkle.framework inside-out per the Sparkle official
    # sandboxing/code-signing doc:
    #   <https://sparkle-project.org/documentation/sandboxing/>
    #
    # Order matters: XPC services first, then Autoupdate, then
    # Updater.app, then the framework itself. Without this order each
    # codesign step invalidates the seal of the parent it just signed.
    #
    # `Downloader.xpc` is signed with `--preserve-metadata=entitlements`:
    # it ships with a no-network-client entitlement assertion that the
    # notary expects to find unchanged. Stripping it changes the
    # entitlement-set the notary ticket claims about that XPC service
    # and is a documented cause of Gatekeeper failing at first launch
    # even when stapler validate passes locally (Sparkle GitHub issues
    # 1550, 1641, 2069; Peter Steinberger, "Sparkle and Tears", 2025).
    SPARKLE="$FRAMEWORKS/Sparkle.framework"
    if [[ -d "$SPARKLE" ]]; then
        for XPC in Installer Downloader; do
            XPC_BUNDLE="$SPARKLE/Versions/B/XPCServices/${XPC}.xpc"
            if [[ -d "$XPC_BUNDLE" ]]; then
                if [[ "$XPC" == "Downloader" ]]; then
                    codesign --force --options=runtime --timestamp \
                        --preserve-metadata=entitlements \
                        --sign "$DEVELOPER_ID" \
                        "$XPC_BUNDLE"
                else
                    codesign --force --options=runtime --timestamp \
                        --sign "$DEVELOPER_ID" \
                        "$XPC_BUNDLE"
                fi
            fi
        done

        AUTOUPDATE="$SPARKLE/Versions/B/Autoupdate"
        if [[ -f "$AUTOUPDATE" ]]; then
            codesign --force --options=runtime --timestamp \
                --sign "$DEVELOPER_ID" \
                "$AUTOUPDATE"
        fi

        UPDATER_APP="$SPARKLE/Versions/B/Updater.app"
        if [[ -d "$UPDATER_APP" ]]; then
            codesign --force --options=runtime --timestamp \
                --sign "$DEVELOPER_ID" \
                "$UPDATER_APP"
        fi

        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            "$SPARKLE"
    fi

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$MACOS/Hippocampus"

    write_build_provenance
    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP"

    echo "Verifying signature..."
    codesign --verify --deep --strict "$APP"
    echo "  Signature valid."
else
    echo "Codesigning (development-only ad-hoc)..."
    if [[ -d "$APPEX_BUNDLE" ]]; then
        codesign --force --sign - \
            --entitlements "$APPEX_ENTITLEMENTS" \
            "$APPEX_BUNDLE"
    fi
    codesign --force --sign - \
        --entitlements "$CAPTURE_HELPER_ENTITLEMENTS" \
        "$MACOS/MCICaptureHelper"
    codesign --force --sign - "$MACOS/mci-agent"
    [[ -f "$MACOS/recall-ui" ]] && codesign --force --sign - "$MACOS/recall-ui"
    [[ -f "$MACOS/onboarding" ]] && codesign --force --sign - "$MACOS/onboarding"
    [[ -f "$MACOS/hippocampus-native-host" ]] && codesign --force --sign - "$MACOS/hippocampus-native-host"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$MACOS/Hippocampus"
    write_build_provenance
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
fi

EXPECTED_SIGNED_TEAM_ID=""
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    EXPECTED_SIGNED_TEAM_ID="${APP_GROUP_ID%%.*}"
fi
if ! hippocampus_verify_signed_app_group \
    "$APP" "$APP_GROUP_ID" "$EXPECTED_SIGNED_TEAM_ID"; then
    fatal "Signed host App Group does not match its bundle/signing identity."
fi
if [[ -d "$APPEX_BUNDLE" ]] && ! hippocampus_verify_signed_app_group \
    "$APPEX_BUNDLE" "$APP_GROUP_ID" "$EXPECTED_SIGNED_TEAM_ID"; then
    fatal "Signed Safari extension App Group does not match its host/signing identity."
fi
echo "  Signed App Group contract valid."

# Verify rpath was added correctly
echo "Verifying rpath..."
if [[ ! -d "$FRAMEWORKS/Sparkle.framework" ]]; then
    if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
        echo "  Skipped for ad-hoc development: Sparkle.framework was not embedded."
    else
        fatal \
            "Sparkle.framework was not embedded" \
            "Build apps/hippocampus with the release profile before Developer ID assembly."
    fi
elif otool -l "$MACOS/Hippocampus" | grep -A 2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
    echo "  rpath OK: @executable_path/../Frameworks present"
else
    echo "  ERROR: rpath missing — app will fail to launch"
    exit 1
fi

# Validate model bundling. Only the explicit development-lite profile may
# authorize omissions; every other assembly treats verifier failures as fatal.
VERIFY_SCRIPT="$REPO_ROOT/scripts/verify-models.sh"
[[ -x "$VERIFY_SCRIPT" ]] || fatal "Required scripts/verify-models.sh is missing or not executable."
if [[ -x "$VERIFY_SCRIPT" ]]; then
    echo ""
    echo "=== Model validation ==="
    if [[ "$DEVELOPMENT_LITE" -eq 1 ]]; then
        "$VERIFY_SCRIPT" --app "$APP" --allow-missing-bundled
    else
        "$VERIFY_SCRIPT" --app "$APP"
    fi
fi

# Launch-verify gate — FATAL.
# Catches the cycle 8.16 class of regression where the .app passes
# syspolicy_check + Gatekeeper + notarization but crashes on launch
# because a structural-init invariant (resource bundle path, rpath,
# missing dyld dep) is wrong. Run after all codesigning so we test the
# actual on-disk artifact that will be packaged.
LAUNCH_VERIFY="$REPO_ROOT/scripts/verify-app-launches.sh"
if [[ -x "$LAUNCH_VERIFY" ]]; then
    echo ""
    echo "=== Launch-verify gate ==="
    VERIFY_CLEAN_HOME=1 VERIFY_EXPECT_ONBOARDING=1 \
        "$LAUNCH_VERIFY" "$APP"
else
    fatal "Required scripts/verify-app-launches.sh is missing or not executable."
fi

# Ad-hoc development bundles use isolated file-key custody, so they can also
# prove the privacy-critical owner-death path without touching the real
# Keychain. Developer ID builds exercise the same code in clean-Mac release
# verification, where their Keychain ACL is available.
PARENT_LIFETIME_VERIFY="$REPO_ROOT/scripts/verify-parent-lifetime.sh"
if [[ "$SIGNING_MODE" == "ad-hoc" && -x "$PARENT_LIFETIME_VERIFY" ]]; then
    echo ""
    echo "=== Parent-lifetime gate ==="
    "$PARENT_LIFETIME_VERIFY" "$APP"
fi

echo ""
echo "=== Done ==="
echo "  $APP"
echo ""
echo "To run:  open $APP"
echo "To test: $MACOS/Hippocampus"
