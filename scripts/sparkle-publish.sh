#!/usr/bin/env bash
set -euo pipefail

# sparkle-publish.sh — Sign a Hippocampus DMG with the Sparkle Ed25519 private
# key and add/replace its <item> entry in appcast.xml.
#
# This script reads the private key from a FILE (not an env var) so it can be
# operated from the same machine that minted the key. The on-disk key file is
# the canonical artifact; backup lives in 1Password / HSM.
#
# Usage:
#   ./scripts/sparkle-publish.sh \
#       --dmg dist/Hippocampus-1.0.0.dmg \
#       --private-key ~/.hippocampus-sparkle-private.key \
#       --release-notes RELEASE_NOTES_1.0.0.md
#
# Optional:
#   --appcast PATH         Existing appcast.xml to merge into (default: dist/appcast.xml)
#   --download-url URL     Full URL for the DMG's <enclosure> tag.
#                          Default: GitHub Releases URL derived from --release-tag.
#   --release-tag TAG      Git tag of the release that hosts the DMG asset.
#                          Default: "v<version>" extracted from DMG filename.
#   --hosting-mode MODE    "vercel-landing" (default) | "ghpages-releases" | "s3"
#                          Only changes the default --download-url shape.
#                          "vercel-landing"  → https://hippocampus-swart.vercel.app/<dmg>
#                          "ghpages-releases" → GitHub Releases asset URL
#                          "s3"               → https://releases.hippocampus.ai/<dmg>
#   --dist DIR             Output directory for appcast.xml (default: dist/)
#   --no-confirm           Skip interactive confirmation for destructive ops.
#   --help                 Show this help.
#
# Idempotency:
#   If appcast.xml already contains an <item> with the same
#   sparkle:shortVersionString, that item is REPLACED (not duplicated). This is
#   intentional so the script can be re-run on the same DMG without producing
#   a corrupt feed. The replacement is interactive unless --no-confirm.
#
# Destructive ops gated by confirmation:
#   - Replacing an existing version's <item> in appcast.xml.
#   - Writing to an --appcast path outside the repo's dist/ directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DMG_PATH=""
KEY_PATH=""
RELEASE_NOTES_PATH=""
APPCAST_PATH=""
DOWNLOAD_URL=""
RELEASE_TAG=""
HOSTING_MODE="vercel-landing"
DIST_DIR="$REPO_ROOT/dist"
NO_CONFIRM=0

usage() {
    cat <<EOF
Usage: sparkle-publish.sh --dmg PATH --private-key PATH --release-notes PATH [OPTIONS]

Sign a Hippocampus DMG with EdDSA and add/replace its appcast.xml item.

Required:
  --dmg PATH             Path to the signed + notarized DMG to publish.
  --private-key PATH     Path to the Sparkle Ed25519 private key file
                         (produced by scripts/sparkle-keygen.sh).
  --release-notes PATH   Path to release notes (.md or .html or .txt).

Optional:
  --appcast PATH         Existing appcast.xml to merge into.
                         Default: \$DIST_DIR/appcast.xml.
  --download-url URL     Full URL where users will fetch the DMG.
  --release-tag TAG      Git tag that publishes the DMG (default: v<version>).
  --hosting-mode MODE    "vercel-landing" (default) | "ghpages-releases" | "s3".
  --dist DIR             Output directory for appcast.xml (default: dist/).
  --no-confirm           Bypass interactive confirmation prompts.
  --help                 Show this help.

Environment:
  SPARKLE_SIGN_UPDATE   Path to Sparkle's sign_update binary (auto-detected).

Exit codes:
  0  Appcast updated (or no-op idempotent re-run).
  1  Missing tool, missing input, validation failure.
  2  User declined a destructive confirmation prompt.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)            DMG_PATH="$2"; shift 2 ;;
        --private-key)    KEY_PATH="$2"; shift 2 ;;
        --release-notes)  RELEASE_NOTES_PATH="$2"; shift 2 ;;
        --appcast)        APPCAST_PATH="$2"; shift 2 ;;
        --download-url)   DOWNLOAD_URL="$2"; shift 2 ;;
        --release-tag)    RELEASE_TAG="$2"; shift 2 ;;
        --hosting-mode)   HOSTING_MODE="$2"; shift 2 ;;
        --dist)           DIST_DIR="$2"; shift 2 ;;
        --no-confirm)     NO_CONFIRM=1; shift ;;
        --help|-h)        usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# --- Validate required inputs ---

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$DMG_PATH"            ]] || die "--dmg is required."
[[ -n "$KEY_PATH"            ]] || die "--private-key is required."
[[ -n "$RELEASE_NOTES_PATH"  ]] || die "--release-notes is required."

[[ -f "$DMG_PATH"           ]] || die "DMG not found: $DMG_PATH"
[[ -f "$KEY_PATH"           ]] || die "Private key not found: $KEY_PATH"
[[ -f "$RELEASE_NOTES_PATH" ]] || die "Release notes not found: $RELEASE_NOTES_PATH"

[[ -s "$KEY_PATH"           ]] || die "Private key file is empty: $KEY_PATH"

# Warn if the private key file is not 0600 (loose perms = leakage risk).
KEY_PERMS=$(stat -f '%Lp' "$KEY_PATH" 2>/dev/null || stat -c '%a' "$KEY_PATH" 2>/dev/null || echo "?")
if [[ "$KEY_PERMS" != "600" ]]; then
    echo "WARNING: Private key permissions are $KEY_PERMS, expected 600." >&2
    echo "         chmod 600 $KEY_PATH" >&2
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

Install Sparkle tooling:
  - brew install --cask sparkle, OR
  - SwiftPM auto-resolved it at apps/hippocampus/.build/artifacts/sparkle/, OR
  - Download the Sparkle 2.x release tarball and set
    SPARKLE_SIGN_UPDATE=/path/to/bin/sign_update.
EOF
    exit 1
fi

# --- Extract version + build ---

DMG_BASENAME=$(basename "$DMG_PATH" .dmg)
VERSION="${DMG_BASENAME#Hippocampus-}"
[[ -n "$VERSION" && "$VERSION" != "$DMG_BASENAME" ]] || \
    die "Could not extract version from DMG filename. Expected Hippocampus-<version>.dmg, got: $DMG_BASENAME"

INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "1")

DMG_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)
[[ -n "$DMG_SIZE" && "$DMG_SIZE" -gt 0 ]] || die "DMG appears empty or unreadable."

# --- Default release tag + download URL ---

if [[ -z "$RELEASE_TAG" ]]; then RELEASE_TAG="v${VERSION}"; fi

if [[ -z "$DOWNLOAD_URL" ]]; then
    case "$HOSTING_MODE" in
        vercel-landing)
            # Same origin as landing/index.html serves the DMG from. When the
            # `hippocampus.ai` custom domain is provisioned (OWNER_TASKS #3),
            # swap this URL together with `SUFeedURL` in Info.plist.
            DOWNLOAD_URL="https://hippocampus-swart.vercel.app/$(basename "$DMG_PATH")"
            ;;
        ghpages-releases)
            DOWNLOAD_URL="https://github.com/amyjainberkeley/hippocampus/releases/download/${RELEASE_TAG}/$(basename "$DMG_PATH")"
            ;;
        s3)
            DOWNLOAD_URL="https://releases.hippocampus.ai/$(basename "$DMG_PATH")"
            ;;
        *) die "Unknown --hosting-mode: $HOSTING_MODE (use vercel-landing, ghpages-releases, or s3)" ;;
    esac
fi

# --- Default appcast path ---
#
# We write directly into the checked-in `landing/appcast.xml` under
# vercel-landing mode so `landing/deploy.sh --prod` picks up the new <item>
# in the same push. Under ghpages-releases mode the historical `dist/appcast.xml`
# staging path is preserved so the docs/appcast-hosting.md GH-Pages recipe still
# works unchanged.

if [[ -z "$APPCAST_PATH" ]]; then
    case "$HOSTING_MODE" in
        vercel-landing) APPCAST_PATH="$REPO_ROOT/landing/appcast.xml" ;;
        *)              APPCAST_PATH="$DIST_DIR/appcast.xml" ;;
    esac
fi
mkdir -p "$(dirname "$APPCAST_PATH")"

# --- Summary + confirm if writing outside dist/ ---

echo "=== Sparkle Appcast Publisher ==="
echo "  DMG:           $DMG_PATH ($DMG_SIZE bytes)"
echo "  Version:       $VERSION (build $BUILD_NUMBER)"
echo "  Release tag:   $RELEASE_TAG"
echo "  Download URL:  $DOWNLOAD_URL"
echo "  Release notes: $RELEASE_NOTES_PATH"
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
    "$REPO_ROOT"/dist/*)      ;;
    "$REPO_ROOT"/landing/*)   ;;
    *)
        echo "WARNING: --appcast points outside dist/ or landing/ — this will write to: $APPCAST_PATH"
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

# Sparkle sign_update accepts the private key either as a positional file
# arg (-f path) on some builds, or via stdin "echo $key | sign_update DMG -f -".
# We support the file form first (cleaner, no key in process args).
SIGN_OUTPUT=""
if "$SIGN_UPDATE" --help 2>&1 | grep -q -- '-f '; then
    SIGN_OUTPUT=$("$SIGN_UPDATE" -f "$KEY_PATH" "$DMG_PATH")
else
    # Fall back to stdin form — key never appears in `ps`.
    SIGN_OUTPUT=$(cat "$KEY_PATH" | "$SIGN_UPDATE" "$DMG_PATH" -f -)
fi

# sign_update prints something like:
#   sparkle:edSignature="..." length="..."
# or just the bare base64 signature (older builds). Handle both.
ED_SIGNATURE=$(printf '%s' "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | head -1 | sed 's/sparkle:edSignature="//;s/"$//' || true)
if [[ -z "$ED_SIGNATURE" ]]; then
    ED_SIGNATURE=$(printf '%s' "$SIGN_OUTPUT" | head -1 | tr -d '[:space:]')
fi
[[ -n "$ED_SIGNATURE" ]] || die "sign_update produced no signature. Raw output:\n$SIGN_OUTPUT"

echo "Signature: ${ED_SIGNATURE:0:20}... (length ${#ED_SIGNATURE})"

# --- Prepare release notes (inline CDATA description) ---
#
# Sparkle supports either <description> (inline HTML) or <sparkle:releaseNotesLink>
# (separate hosted file). Inline is friendlier for first-50 dogfooders since it
# works regardless of the hosting-side CORS/CDN setup.

RELEASE_NOTES_RAW=$(cat "$RELEASE_NOTES_PATH")
# Escape any embedded `]]>` so the CDATA closer can't be smuggled in via notes.
RELEASE_NOTES_SAFE=$(printf '%s' "$RELEASE_NOTES_RAW" | sed 's/\]\]>/]]]]><![CDATA[>/g')

# --- Build the new <item> XML ---

PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

TMP_ITEM=$(mktemp -t sparkle-item.XXXXXX)
trap 'rm -f "$TMP_ITEM"' EXIT

cat > "$TMP_ITEM" <<ITEM_EOF
        <item>
            <title>Hippocampus ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
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

if [[ ! -f "$APPCAST_PATH" ]]; then
    # Bootstrap a fresh feed. Newest <item> goes first; nothing to merge.
    TMP_APPCAST=$(mktemp -t sparkle-appcast.XXXXXX)
    {
        cat <<HEADER_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Hippocampus Changelog</title>
        <link>https://hippocampus.ai</link>
        <description>Hippocampus app updates</description>
        <language>en</language>
HEADER_EOF
        cat "$TMP_ITEM"
        cat <<'FOOTER_EOF'
    </channel>
</rss>
FOOTER_EOF
    } > "$TMP_APPCAST"
    mv "$TMP_APPCAST" "$APPCAST_PATH"
    echo "Created new appcast: $APPCAST_PATH"
else
    # Merge: drop any existing <item> with the same shortVersionString, then
    # insert the new item immediately after </language> so the newest version
    # is always first in the feed (Sparkle iterates the feed in order; first
    # eligible item wins, so ordering matters when phased rollouts are added).
    TMP_FILTERED=$(mktemp -t sparkle-filtered.XXXXXX)
    TMP_OUT=$(mktemp -t sparkle-out.XXXXXX)

    # Strip any existing <item>...</item> block whose shortVersionString matches.
    awk -v ver="$VERSION" '
        BEGIN { in_item=0; buf="" }
        /<item>/ { in_item=1; buf=$0 ORS; next }
        in_item {
            buf = buf $0 ORS
            if ($0 ~ /<\/item>/) {
                # Decide whether to keep or drop this buffered item.
                # Match the exact shortVersionString tag to avoid accidental
                # substring hits (e.g. "1.0" matching "1.0.10").
                pattern = "<sparkle:shortVersionString>" ver "</sparkle:shortVersionString>"
                if (index(buf, pattern) > 0) {
                    # drop
                } else {
                    printf "%s", buf
                }
                in_item=0; buf=""
            }
            next
        }
        { print }
    ' "$APPCAST_PATH" > "$TMP_FILTERED"

    # Splice the new item in directly after </language>. Sparkle picks by
    # highest sparkle:version, so document order is cosmetic — we put the most
    # recently published item at the top for human readability. If the feed
    # has no </language> tag (older / hand-edited feed), fall back to
    # inserting just before </channel>.
    if grep -F -q "</language>" "$TMP_FILTERED"; then
        # Use awk to insert TMP_ITEM contents after first </language>
        awk -v itemfile="$TMP_ITEM" '
            /<\/language>/ && !done {
                print
                while ((getline line < itemfile) > 0) print line
                close(itemfile)
                done=1
                next
            }
            { print }
        ' "$TMP_FILTERED" > "$TMP_OUT"
    else
        awk -v itemfile="$TMP_ITEM" '
            /<\/channel>/ && !done {
                while ((getline line < itemfile) > 0) print line
                close(itemfile)
                done=1
            }
            { print }
        ' "$TMP_FILTERED" > "$TMP_OUT"
    fi

    mv "$TMP_OUT" "$APPCAST_PATH"
    rm -f "$TMP_FILTERED"

    if [[ "$REPLACING_VERSION" -eq 1 ]]; then
        echo "Replaced version $VERSION item in: $APPCAST_PATH"
    else
        echo "Added version $VERSION item to: $APPCAST_PATH"
    fi
fi

# --- Optional: run appcast-validator if installed ---

if command -v appcast-validator &>/dev/null; then
    echo ""
    echo "--- Validating appcast.xml ---"
    if appcast-validator "$APPCAST_PATH"; then
        echo "Appcast validates."
    else
        echo "WARNING: appcast-validator reported issues — review before publishing." >&2
    fi
fi

# --- Sanity check the rendered XML ---

if command -v xmllint &>/dev/null; then
    if ! xmllint --noout "$APPCAST_PATH" 2>/dev/null; then
        die "Rendered appcast.xml is not well-formed XML — refusing. Inspect: $APPCAST_PATH"
    fi
fi

echo ""
echo "=== Done ==="
echo "  Appcast:  $APPCAST_PATH"
echo "  Version:  $VERSION (build $BUILD_NUMBER)"
echo "  DMG URL:  $DOWNLOAD_URL"
echo ""
echo "Next:"
case "$HOSTING_MODE" in
    vercel-landing)
        echo "  1. Commit the updated $APPCAST_PATH to the current branch."
        echo "  2. Copy the DMG next to it and deploy to Vercel:"
        echo "       cp $DMG_PATH $REPO_ROOT/landing/"
        echo "       (landing/deploy.sh will do the copy + \`vercel deploy --prod\` for you.)"
        echo "  3. Verify:  curl -sI $DOWNLOAD_URL | head -1"
        echo "             curl -sS https://hippocampus-swart.vercel.app/appcast.xml | xmllint --noout - && echo OK"
        ;;
    *)
        echo "  1. Upload $DMG_PATH as a release asset for tag $RELEASE_TAG:"
        echo "       gh release create $RELEASE_TAG --notes-file $RELEASE_NOTES_PATH $DMG_PATH"
        echo "  2. Commit + push $APPCAST_PATH to the public appcast repo"
        echo "     (see docs/appcast-hosting.md for the GH Pages procedure)."
        ;;
esac
