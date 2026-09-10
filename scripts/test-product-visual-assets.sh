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
DAILY_MEMORY="$REPO_ROOT/apps/recall-ui/Sources/RecallUI/DailyMemoryView.swift"
MEASURED_INPUT="$REPO_ROOT/apps/recall-ui/Sources/RecallUI/MeasuredInputView.swift"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for source in "$BRAND/AppIcon.svg" "$BRAND/AppIcon-template.svg"; do
    rg -qi 'Hippocampus brain mark' "$source" \
        || fail "$(basename "$source") is not the canonical brain mark"
    if rg -qi '#7AFFC1|#3AFDC8|rotate\(|squiggle' "$source"; then
        fail "$(basename "$source") contains retired mint or rotated artwork"
    fi
done

python3 - "$BRAND" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

brand = Path(sys.argv[1])
ns = {"svg": "http://www.w3.org/2000/svg"}
geometry = None
for name in ("AppIcon.svg", "AppIcon-template.svg", "hippocampus-icon.svg"):
    root = ET.parse(brand / name).getroot()
    paths = sorted(path.attrib["d"] for path in root.findall(".//svg:path", ns))
    assert len(paths) == 4, f"{name}: expected two lobes and two folds"
    assert geometry is None or paths == geometry, f"{name}: inconsistent brain geometry"
    geometry = paths
    maximum_frames = 1 if name == "AppIcon.svg" else 0
    assert len(root.findall(".//svg:rect", ns)) <= maximum_frames, f"{name}: nested icon frames"
PY

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
rg -q 'CGSize\(width: 108, height: 68\)' "$DAILY_MEMORY" \
    || fail "resume evidence does not use its stable compact thumbnail size"
rg -q 'Text\(verbatim: point.detail\)' "$DAILY_MEMORY" \
    || fail "resume rows do not render their source-derived detail"
rg -q '\.sheet\(item: \$selectedEvidence' "$DAILY_MEMORY" \
    || fail "resume evidence is not inspectable"
rg -q 'static let primary:.*\[\.now, \.search, \.timeline\]' "$MEMORY_WORKSPACE" \
    || fail "primary navigation must separate Today, Search and History"
rg -q 'MeasuredInputView\(summary: summary\)' "$DAILY_MEMORY" \
    || fail "Today does not connect its measured interval summary"
rg -q 'SectorMark\(angle:' "$MEASURED_INPUT" \
    || fail "measured activity distribution is missing"
rg -q '\.defaultSize\(width: 920, height: 620\)' "$RECALL_APP" \
    || fail "Recall default window lost its compact native size"

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
printf 'PASS: product visual assets use the light brain mark system\n'
