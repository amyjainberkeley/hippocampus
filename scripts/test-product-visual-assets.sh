#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BRAND="$REPO_ROOT/assets/branding"
ONBOARDING="$REPO_ROOT/apps/onboarding/Sources/Onboarding"
RECALL_APP="$REPO_ROOT/apps/recall-ui/Sources/RecallUI/MCIRecallApp.swift"
ONBOARDING_APP="$ONBOARDING/OnboardingApp.swift"
PREFERENCES_APP="$REPO_ROOT/apps/hippocampus/Sources/Hippocampus/PreferencesWindow.swift"
MEMORY_WORKSPACE="$REPO_ROOT/apps/recall-ui/Sources/RecallUI/MemoryWorkspaceView.swift"
EVIDENCE_THUMBNAIL="$REPO_ROOT/apps/recall-ui/Sources/RecallUI/EvidenceThumbnail.swift"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for source in "$BRAND/AppIcon.svg" "$BRAND/AppIcon-template.svg"; do
    rg -qi 'memory aperture mark' "$source" \
        || fail "$(basename "$source") is not the canonical aperture mark"
    if rg -qi '#7AFFC1|#3AFDC8|rotate\(|squiggle' "$source"; then
        fail "$(basename "$source") contains retired mint or rotated artwork"
    fi
done

rg -q '\.fill\(\.ultraThinMaterial\)' \
    "$ONBOARDING/SharedComponents/OnboardingMaterialBackdrop.swift" \
    || fail "onboarding shell must use the native translucent material"
if rg -q 'RadialGradient|LinearGradient' "$ONBOARDING"; then
    fail "onboarding must not restore a decorative gradient backdrop"
fi

for root in "$RECALL_APP" "$ONBOARDING_APP" "$PREFERENCES_APP"; do
    rg -q '\.preferredColorScheme\(\.light\)' "$root" \
        || fail "$(basename "$root") does not pin the V1 window to light appearance"
done

rg -q 'panel\.appearance = NSAppearance\(named: \.aqua\)' "$PREFERENCES_APP" \
    || fail "Preferences native panel chrome does not pin the V1 Aqua appearance"

if rg -q '\.blur\(' "$EVIDENCE_THUMBNAIL"; then
    fail "evidence pixels must remain inspectable; blur belongs on the surrounding material"
fi
rg -q 'CGSize\(width: 152, height: 86\)' "$MEMORY_WORKSPACE" \
    || fail "recent-evidence previews do not use the inspectable 16:9 card size"
rg -q 'Text\(Formatters\.evidenceSummary\(hit\)\)' "$MEMORY_WORKSPACE" \
    || fail "recent-evidence cards do not render a cleaned evidence summary"
rg -q '\.popover\(item: \$selectedHit' "$MEMORY_WORKSPACE" \
    || fail "recent-evidence cards are not inspectable"
rg -q 'evidenceFilmstripHeight\(' "$MEMORY_WORKSPACE" \
    || fail "memory workspace does not compact the filmstrip in short windows"
rg -q '\.defaultSize\(width: 1024, height: 700\)' "$RECALL_APP" \
    || fail "Recall default window is too small for the evidence workspace"

if rg -q 'Use System Appearance|follows the current macOS light or dark appearance' "$RECALL_APP"; then
    fail "Recall still advertises the retired adaptive appearance control"
fi

while read -r relative expected_width expected_height; do
    image="$BRAND/$relative"
    width="$(sips -g pixelWidth "$image" | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "$image" | awk '/pixelHeight:/ {print $2}')"
    [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] \
        || fail "$relative is ${width}x${height}; expected ${expected_width}x${expected_height}"
done <<'SIZES'
statusbar-icon.png 22 22
statusbar-icon@2x.png 44 44
statusbar-icon@3x.png 66 66
AppIcon.iconset/icon_16x16.png 16 16
AppIcon.iconset/icon_512x512@2x.png 1024 1024
SIZES

xcrun swift - "$BRAND/AppIcon.iconset/icon_512x512@2x.png" \
    "$BRAND/statusbar-icon@3x.png" <<'SWIFT' \
    || fail "icon pixels lost transparency or restored the retired palette"
import CoreGraphics
import Foundation
import ImageIO

for path in CommandLine.arguments.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { exit(2) }

    let width = 64
    let height = 64
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { exit(3) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var transparent = 0
    var turquoise = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let r = Int(pixels[offset])
        let g = Int(pixels[offset + 1])
        let b = Int(pixels[offset + 2])
        let a = Int(pixels[offset + 3])
        if a < 16 { transparent += 1 }
        if g > 170 && g > r * 2 && g > b + 25 { turquoise += 1 }
    }
    let count = width * height
    guard Double(transparent) / Double(count) > 0.02 else { exit(4) }
    guard Double(turquoise) / Double(count) < 0.002 else { exit(5) }
}
SWIFT

for size in 16 19 32 38 48 72 96 128; do
    cmp "$REPO_ROOT/extensions/safari/icons/toolbar-$size.png" \
        "$REPO_ROOT/extensions/chromium/icons/toolbar-$size.png" \
        || fail "Safari and Chromium toolbar-$size.png differ"
done

"$SCRIPT_DIR/test-screenshot-assets.sh"
printf 'PASS: product visual assets use the light aperture system\n'
