#!/usr/bin/env bash
# Regenerates every hi mark asset from
# apps/hippocampus/Sources/HippocampusKit/Brand/HiMarkGeometry.swift.
#
#   scripts/generate-brand-assets.sh          write the SVGs and PNGs, then
#                                             the .icns, the installer's
#                                             volume icon and the website icon
#   scripts/generate-brand-assets.sh --check  fail if the checked-in SVGs no
#                                             longer match the geometry
#
# PNG bytes can differ between macOS versions, so --check compares SVGs only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEOMETRY="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/Brand/HiMarkGeometry.swift"
GENERATOR="$SCRIPT_DIR/brand/GenerateBrandAssets.swift"
BRAND="$REPO_ROOT/assets/branding"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-brand.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

case "${1:-}" in
    --check)
        xcrun swiftc -Onone -parse-as-library -o "$TMP/generate" "$GEOMETRY" "$GENERATOR"
        "$TMP/generate" --svg "$TMP/svg"
        status=0
        for svg in "$TMP"/svg/*.svg; do
            name="$(basename "$svg")"
            if ! cmp -s "$svg" "$BRAND/$name"; then
                printf 'FAIL: assets/branding/%s does not match the geometry; run scripts/generate-brand-assets.sh\n' "$name" >&2
                status=1
            fi
        done
        if [[ "$status" -eq 0 ]]; then
            printf 'PASS: the brand SVGs match HiMarkGeometry.swift\n'
        fi
        exit "$status"
        ;;
    "")
        ;;
    *)
        printf 'usage: %s [--check]\n' "$0" >&2
        exit 64
        ;;
esac

xcrun swiftc -O -parse-as-library -o "$TMP/generate" "$GEOMETRY" "$GENERATOR"
"$TMP/generate" "$REPO_ROOT"
iconutil -c icns "$BRAND/AppIcon.iconset" -o "$BRAND/AppIcon.icns"
cp "$BRAND/AppIcon.icns" "$REPO_ROOT/assets/installer/volume-icon.icns"
cp "$BRAND/AppIcon.iconset/icon_512x512@2x.png" "$REPO_ROOT/website/public/icon.png"
printf 'Wrote the hi mark assets. Check them with scripts/test-product-visual-assets.sh.\n'
