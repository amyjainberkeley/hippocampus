#!/usr/bin/env bash
set -euo pipefail

# sparkle-publish.sh — Sign a Hippocampus DMG with the Sparkle Ed25519 private
# key, add or replace its <item> in appcast.xml, then sign the appcast itself.
#
# The appcast is a release asset. The app's SUFeedURL is
#   https://github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml
# so the newest published release's appcast.xml is the feed, and publishing a
# release publishes its update. No Pages site or other host is involved.
#
# This owner-operated path reads the exported private seed from a FILE. The
# named Sparkle Keychain account is the local source and the exported file is
# the owner backup/CI import artifact. The key never appears in arguments,
# output or the environment of other commands.
#
# Usage:
#   ./scripts/sparkle-publish.sh \
#       --dmg dist/Hippocampus-1.0.0.dmg \
#       --private-key ~/.hippocampus-sparkle-private.key \
#       --changelog-notes
#
# Release notes (one of):
#   --release-notes PATH   Notes to embed: .md is shown as Markdown, .txt as
#                          plain text, .html as HTML.
#   --changelog-notes      Embed the CHANGELOG.md section for this version.
#
# Optional:
#   --appcast PATH         Appcast to write; an existing one is merged into
#                          (default: <dist>/appcast.xml)
#   --download-url URL     Full URL for the DMG's <enclosure> tag.
#                          Default: this version's GitHub release asset.
#   --release-tag TAG      Git tag of the release that hosts the DMG asset.
#                          Default: "v<version>" extracted from DMG filename.
#   --dist DIR             Output directory for appcast.xml (default: dist/)
#   --no-confirm           Skip interactive confirmation for destructive ops.
#   --help                 Show this help.
#
# Idempotency:
#   If appcast.xml already contains an <item> with the same
#   sparkle:shortVersionString, that item is REPLACED (not duplicated), and
#   the feed is signed again. The replacement is interactive unless
#   --no-confirm.
#
# Destructive ops gated by confirmation:
#   - Replacing an existing version's <item> in appcast.xml.
#   - Writing to an --appcast path outside the repo's dist/ directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY="amyjainberkeley/hippocampus"
PROJECT_LINK="https://github.com/$REPOSITORY"
INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

DMG_PATH=""
KEY_PATH=""
RELEASE_NOTES_PATH=""
CHANGELOG_NOTES=0
APPCAST_PATH=""
DOWNLOAD_URL=""
RELEASE_TAG=""
DIST_DIR="$REPO_ROOT/dist"
NO_CONFIRM=0

usage() {
    cat <<EOF
Usage: sparkle-publish.sh --dmg PATH --private-key PATH
                          (--release-notes PATH | --changelog-notes) [OPTIONS]

Sign a Hippocampus DMG with EdDSA, add or replace its appcast.xml item, and
sign the appcast. Upload appcast.xml with the DMG to the same GitHub release.

Required:
  --dmg PATH             Path to the signed + notarized DMG to publish.
  --private-key PATH     Path to the Sparkle Ed25519 private key file, mode 600
                         (produced by scripts/sparkle-keygen.sh).
  --release-notes PATH   Notes to embed (.md Markdown, .txt plain text, .html).
  --changelog-notes      Or: embed this version's CHANGELOG.md section.

Optional:
  --appcast PATH         Appcast to write (default: \$DIST_DIR/appcast.xml).
  --download-url URL     Full URL where users will fetch the DMG.
  --release-tag TAG      Git tag that publishes the DMG (default: v<version>).
  --dist DIR             Output directory for appcast.xml (default: dist/).
  --no-confirm           Bypass interactive confirmation prompts.
  --help                 Show this help.

Environment:
  SPARKLE_SIGN_UPDATE   Path to Sparkle's sign_update binary (auto-detected).

Exit codes:
  0  Appcast written and signed.
  1  Missing tool, missing input, validation failure.
  2  User declined a destructive confirmation prompt.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)             DMG_PATH="$2"; shift 2 ;;
        --private-key)     KEY_PATH="$2"; shift 2 ;;
        --release-notes)   RELEASE_NOTES_PATH="$2"; shift 2 ;;
        --changelog-notes) CHANGELOG_NOTES=1; shift ;;
        --appcast)         APPCAST_PATH="$2"; shift 2 ;;
        --download-url)    DOWNLOAD_URL="$2"; shift 2 ;;
        --release-tag)     RELEASE_TAG="$2"; shift 2 ;;
        --dist)            DIST_DIR="$2"; shift 2 ;;
        --no-confirm)      NO_CONFIRM=1; shift ;;
        --help|-h)         usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# --- Validate required inputs ---

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$DMG_PATH" ]] || die "--dmg is required."
[[ -n "$KEY_PATH" ]] || die "--private-key is required."
if [[ -n "$RELEASE_NOTES_PATH" && "$CHANGELOG_NOTES" -eq 1 ]]; then
    die "Pass --release-notes or --changelog-notes, not both."
fi
[[ -n "$RELEASE_NOTES_PATH" || "$CHANGELOG_NOTES" -eq 1 ]] \
    || die "--release-notes PATH or --changelog-notes is required."

[[ -f "$DMG_PATH" ]] || die "DMG not found: $DMG_PATH"
[[ -f "$KEY_PATH" ]] || die "Private key not found: $KEY_PATH"
[[ -s "$KEY_PATH" ]] || die "Private key file is empty: $KEY_PATH"
if [[ -n "$RELEASE_NOTES_PATH" ]]; then
    [[ -f "$RELEASE_NOTES_PATH" ]] || die "Release notes not found: $RELEASE_NOTES_PATH"
fi

# A private key anyone else on this Mac can read is not private.
KEY_PERMS=$(stat -f '%Lp' "$KEY_PATH" 2>/dev/null || stat -c '%a' "$KEY_PATH" 2>/dev/null || echo "?")
if [[ ! "$KEY_PERMS" =~ ^[0-7]?[0-7]00$ ]]; then
    die "Private key permissions are $KEY_PERMS; only you may read it: chmod 600 $KEY_PATH"
fi

# --- Find sign_update ---

find_sign_update() {
    if [[ -n "${SPARKLE_SIGN_UPDATE:-}" && -x "${SPARKLE_SIGN_UPDATE}" ]]; then
        echo "$SPARKLE_SIGN_UPDATE"; return 0
    fi
    local swiftpm_path="$REPO_ROOT/apps/hippocampus/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    if [[ -x "$swiftpm_path" ]]; then echo "$swiftpm_path"; return 0; fi
    local fw_bases=(
        "$REPO_ROOT/apps/hippocampus/.build"
        "$HOME/Library/Developer/Xcode/DerivedData"
    )
    for base in "${fw_bases[@]}"; do
        if [[ -d "$base" ]]; then
            local found
            found=$(find "$base" -path "*/Sparkle.framework/Versions/B/bin/sign_update" 2>/dev/null | head -1 || true)
            if [[ -n "$found" && -x "$found" ]]; then echo "$found"; return 0; fi
        fi
    done
    if command -v sign_update &>/dev/null; then command -v sign_update; return 0; fi
    return 1
}

if ! SIGN_UPDATE=$(find_sign_update); then
    cat <<EOF >&2
ERROR: Sparkle sign_update not found.

Resolve the app's packages (scripts/swift-package.sh build --package-path
apps/hippocampus puts it in apps/hippocampus/.build/artifacts/sparkle/), or set
SPARKLE_SIGN_UPDATE=/path/to/bin/sign_update.
EOF
    exit 1
fi

# --- Extract version, build and minimum macOS ---

DMG_BASENAME=$(basename "$DMG_PATH" .dmg)
VERSION="${DMG_BASENAME#Hippocampus-}"
[[ -n "$VERSION" && "$VERSION" != "$DMG_BASENAME" ]] || \
    die "Could not extract version from DMG filename. Expected Hippocampus-<version>.dmg, got: $DMG_BASENAME"

BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || true)
MINIMUM_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$INFO_PLIST" 2>/dev/null || true)
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "Info.plist has no positive CFBundleVersion: $INFO_PLIST"
[[ -n "$MINIMUM_SYSTEM" ]] || die "Info.plist has no LSMinimumSystemVersion: $INFO_PLIST"

DMG_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)
[[ -n "$DMG_SIZE" && "$DMG_SIZE" -gt 0 ]] || die "DMG appears empty or unreadable."

# --- Default release tag + download URL ---

if [[ -z "$RELEASE_TAG" ]]; then RELEASE_TAG="v${VERSION}"; fi
if [[ -z "$DOWNLOAD_URL" ]]; then
    DOWNLOAD_URL="$PROJECT_LINK/releases/download/${RELEASE_TAG}/$(basename "$DMG_PATH")"
fi

# --- Release notes ---

NOTES_SCRATCH=$(mktemp -d -t sparkle-publish)
trap 'rm -rf "$NOTES_SCRATCH"' EXIT

if [[ "$CHANGELOG_NOTES" -eq 1 ]]; then
    [[ -f "$CHANGELOG" ]] || die "CHANGELOG.md not found: $CHANGELOG"
    RELEASE_NOTES_PATH="$NOTES_SCRATCH/notes-$VERSION.md"
    # The lines under "## [VERSION]", up to the next release heading, without
    # the blank lines around them.
    awk -v heading="## [$VERSION]" '
        /^## \[/ {
            if (in_section) exit
            if (index($0, heading) == 1) { in_section = 1; next }
        }
        in_section { lines[++count] = $0 }
        END {
            first = 1
            while (first <= count && lines[first] ~ /^[[:space:]]*$/) first++
            last = count
            while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
            for (i = first; i <= last; i++) print lines[i]
        }
    ' "$CHANGELOG" >"$RELEASE_NOTES_PATH"
    grep -q '[^[:space:]]' "$RELEASE_NOTES_PATH" \
        || die "CHANGELOG.md has no notes under ## [$VERSION]."
fi

case "$RELEASE_NOTES_PATH" in
    *.md|*.markdown) DESCRIPTION_OPEN='<description sparkle:format="markdown">' ;;
    *.txt)           DESCRIPTION_OPEN='<description sparkle:format="plain-text">' ;;
    *.html|*.htm)    DESCRIPTION_OPEN='<description>' ;;
    *) die "Release notes must be .md, .txt or .html: $RELEASE_NOTES_PATH" ;;
esac

# --- Default appcast path ---

if [[ -z "$APPCAST_PATH" ]]; then APPCAST_PATH="$DIST_DIR/appcast.xml"; fi
mkdir -p "$(dirname "$APPCAST_PATH")"

# --- Summary + confirm if writing outside dist/ ---

echo "=== Sparkle Appcast Publisher ==="
echo "  DMG:           $DMG_PATH ($DMG_SIZE bytes)"
echo "  Version:       $VERSION (build $BUILD_NUMBER, macOS $MINIMUM_SYSTEM or later)"
echo "  Release tag:   $RELEASE_TAG"
echo "  Download URL:  $DOWNLOAD_URL"
echo "  Release notes: $([[ "$CHANGELOG_NOTES" -eq 1 ]] && echo "CHANGELOG.md [$VERSION]" || echo "$RELEASE_NOTES_PATH")"
echo "  Appcast:       $APPCAST_PATH"
echo "  Private key:   $KEY_PATH (perms $KEY_PERMS)"
echo "  sign_update:   $SIGN_UPDATE"
echo ""

confirm() {
    local prompt="$1"
    if [[ "$NO_CONFIRM" -eq 1 ]]; then return 0; fi
    read -r -p "$prompt [y/N] " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

case "$APPCAST_PATH" in
    "$REPO_ROOT"/dist/*) ;;
    *)
        echo "NOTE: --appcast is outside dist/; this writes: $APPCAST_PATH"
        if ! confirm "Write appcast.xml to this location?"; then
            echo "Aborted." >&2; exit 2
        fi
        ;;
esac

# --- Detect idempotent replacement up front ---

REPLACING_VERSION=0
if [[ -f "$APPCAST_PATH" ]]; then
    if grep -F -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_PATH"; then
        REPLACING_VERSION=1
        echo "NOTE: $APPCAST_PATH already has an item for version $VERSION."
        echo "      It will be REPLACED (idempotent re-run)."
        if ! confirm "Proceed with replacement?"; then
            echo "Aborted." >&2; exit 2
        fi
    fi
fi

# --- Sign the DMG ---

echo "--- Signing DMG with EdDSA ---"

# The key is read from its file by sign_update itself, so it never appears in
# `ps`, the environment or this script's output.
SIGN_OUTPUT=$("$SIGN_UPDATE" -f "$KEY_PATH" "$DMG_PATH")

# sign_update prints: sparkle:edSignature="..." length="..."
ED_SIGNATURE=$(printf '%s' "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | head -1 | sed 's/sparkle:edSignature="//;s/"$//' || true)
SIGNED_LENGTH=$(printf '%s' "$SIGN_OUTPUT" | grep -o 'length="[0-9]*"' | head -1 | tr -cd '0-9' || true)
[[ -n "$ED_SIGNATURE" ]] || die "sign_update produced no signature."
[[ "$SIGNED_LENGTH" == "$DMG_SIZE" ]] || die "sign_update signed $SIGNED_LENGTH bytes, but the DMG has $DMG_SIZE."

echo "Signature: ${ED_SIGNATURE:0:20}... (length ${#ED_SIGNATURE})"

# --- Prepare release notes (inline CDATA description) ---
#
# Inline notes need no other host. Escape any embedded `]]>` so the CDATA
# closer can't be smuggled in via notes.

RELEASE_NOTES_SAFE=$(sed 's/\]\]>/]]]]><![CDATA[>/g' "$RELEASE_NOTES_PATH")

# --- Build the new <item> XML ---

PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

TMP_ITEM="$NOTES_SCRATCH/item.xml"

cat > "$TMP_ITEM" <<ITEM_EOF
        <item>
            <title>Hippocampus ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM}</sparkle:minimumSystemVersion>
            ${DESCRIPTION_OPEN}<![CDATA[
${RELEASE_NOTES_SAFE}
]]></description>
            <enclosure url="${DOWNLOAD_URL}"
                       sparkle:edSignature="${ED_SIGNATURE}"
                       length="${DMG_SIZE}"
                       type="application/octet-stream" />
        </item>
ITEM_EOF

# --- Splice into appcast.xml ---

echo ""
echo "--- Writing appcast.xml ---"

TMP_APPCAST="$NOTES_SCRATCH/appcast.xml"
if [[ ! -f "$APPCAST_PATH" ]]; then
    {
        cat <<HEADER_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Hippocampus</title>
        <link>${PROJECT_LINK}</link>
        <description>Hippocampus updates</description>
        <language>en</language>
HEADER_EOF
        cat "$TMP_ITEM"
        cat <<'FOOTER_EOF'
    </channel>
</rss>
FOOTER_EOF
    } > "$TMP_APPCAST"
    echo "Creating new appcast: $APPCAST_PATH"
else
    # Merge: drop any existing <item> with the same shortVersionString, then
    # insert the new item immediately after </language> so the newest version
    # is first. An old feed signature stays until sign_update replaces it.
    TMP_FILTERED="$NOTES_SCRATCH/filtered.xml"

    awk -v ver="$VERSION" '
        BEGIN { in_item=0; buf="" }
        /<item>/ { in_item=1; buf=$0 ORS; next }
        in_item {
            buf = buf $0 ORS
            if ($0 ~ /<\/item>/) {
                # Match the exact shortVersionString tag to avoid accidental
                # substring hits (e.g. "1.0" matching "1.0.10").
                pattern = "<sparkle:shortVersionString>" ver "</sparkle:shortVersionString>"
                if (index(buf, pattern) == 0) {
                    printf "%s", buf
                }
                in_item=0; buf=""
            }
            next
        }
        { print }
    ' "$APPCAST_PATH" > "$TMP_FILTERED"

    if grep -F -q "</language>" "$TMP_FILTERED"; then
        awk -v itemfile="$TMP_ITEM" '
            /<\/language>/ && !done {
                print
                while ((getline line < itemfile) > 0) print line
                close(itemfile)
                done=1
                next
            }
            { print }
        ' "$TMP_FILTERED" > "$TMP_APPCAST"
    else
        awk -v itemfile="$TMP_ITEM" '
            /<\/channel>/ && !done {
                while ((getline line < itemfile) > 0) print line
                close(itemfile)
                done=1
            }
            { print }
        ' "$TMP_FILTERED" > "$TMP_APPCAST"
    fi

    if [[ "$REPLACING_VERSION" -eq 1 ]]; then
        echo "Replacing version $VERSION item in: $APPCAST_PATH"
    else
        echo "Adding version $VERSION item to: $APPCAST_PATH"
    fi
fi

# --- Check, sign and verify the feed before it replaces the old one ---

if command -v xmllint &>/dev/null; then
    xmllint --noout "$TMP_APPCAST" 2>/dev/null \
        || die "Rendered appcast.xml is not well-formed XML — refusing. Inspect: $TMP_APPCAST"
fi

echo ""
echo "--- Signing appcast.xml with EdDSA ---"
# sign_update embeds the feed's signature at its end. Change nothing after
# this; an edited feed must be signed again.
"$SIGN_UPDATE" -f "$KEY_PATH" "$TMP_APPCAST" >/dev/null
"$SIGN_UPDATE" --verify -f "$KEY_PATH" "$TMP_APPCAST" >/dev/null \
    || die "The signed appcast does not verify with the key that signed it."
grep -q '<!-- sparkle-signatures:' "$TMP_APPCAST" \
    || die "sign_update did not embed a signature in the appcast."
mv -f "$TMP_APPCAST" "$APPCAST_PATH"

echo ""
echo "=== Done ==="
echo "  Appcast:  $APPCAST_PATH (signed)"
echo "  Version:  $VERSION (build $BUILD_NUMBER)"
echo "  DMG URL:  $DOWNLOAD_URL"
echo ""
echo "Next: upload appcast.xml to the $RELEASE_TAG release with the DMG. When"
echo "that release is published as Latest, installed copies see the update."
