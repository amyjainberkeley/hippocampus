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
    rg -qi 'Hippocampus hi mark' "$source" \
        || fail "$(basename "$source") is not the canonical hi mark"
    if rg -qi '#7AFFC1|#3AFDC8|#2A2D35|#0B0C10|#9CC3FF|golden-ratio|rotate\(|squiggle|face' "$source"; then
        fail "$(basename "$source") contains retired artwork"
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
    by_id = {el.attrib["id"]: el for el in root.iter() if "id" in el.attrib}
    assert "letters" in by_id and "dot" in by_id, f"{name}: expected the letters and the dot"
    shape = (by_id["letters"].attrib["d"],
             tuple(by_id["dot"].attrib[k] for k in ("cx", "cy", "r")))
    assert geometry is None or shape == geometry, f"{name}: inconsistent hi geometry"
    geometry = shape
    tiles = 1 if name == "AppIcon.svg" else 0
    assert ("tile" in by_id) == bool(tiles), f"{name}: the tile belongs to the app icon only"
    if not tiles:
        assert root.attrib["viewBox"] == "-4 -6 102 110", f"{name}: unexpected viewBox"
for name in ("hi-states-light.svg", "hi-states-dark.svg"):
    ET.parse(brand / name)
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
rg -U -q 'case overview\n\s*case ask\n\s*case you' "$MEMORY_WORKSPACE" \
    || fail "the window must have three places: Overview, Ask and You"
rg -q 'case \.ask:\s*$' "$MEMORY_WORKSPACE" && rg -q 'AskPlace\(' "$MEMORY_WORKSPACE" \
    || fail "Ask must show its own place"
rg -q 'OverviewPlace\(model: overview' "$MEMORY_WORKSPACE" && rg -q 'YouPlace\(model: you' "$MEMORY_WORKSPACE" \
    || fail "Overview and You must show their own places"
if rg -q 'PendingPlace|DailyMemoryView\(|EpisodesView\(|SourcesWorkspaceView|MeasuredInputView\(' "$MEMORY_WORKSPACE"; then
    fail "the window must not show Today, Sessions, Connections or the input chart"
fi
if rg -q 'SectorMark\(|GlobalRecallPopup|\b(DailyMemoryView|MeasuredInputView|EpisodesView|BriefEvidenceView|BriefView|TimelineStripView|PrivacyMomentsView|WorkspaceSettingsView|PendingPlace)\b' \
    "$REPO_ROOT/apps/recall-ui/Sources"; then
    fail "the window's retired views, its input chart and its popup must stay gone"
fi
rg -q '\.defaultSize\(width: 1100, height: 720\)' "$RECALL_APP" \
    || fail "the window must open at 1100 by 720, wide enough for a list beside its detail"

if rg -q 'Use System Appearance|follows the current macOS light or dark appearance' "$RECALL_APP"; then
    fail "Recall still advertises the retired adaptive appearance control"
fi

while read -r relative expected_width expected_height; do
    image="$REPO_ROOT/$relative"
    width="$(sips -g pixelWidth "$image" | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "$image" | awk '/pixelHeight:/ {print $2}')"
    [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] \
        || fail "$relative is ${width}x${height}; expected ${expected_width}x${expected_height}"
done < <(
    while read -r name side; do
        printf 'assets/branding/AppIcon.iconset/%s %s %s\n' "$name" "$side" "$side"
    done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES
    for browser in chromium safari; do
        for size in 16 19 32 38 48 72 96 128; do
            printf 'extensions/%s/icons/toolbar-%s.png %s %s\n' "$browser" "$size" "$size" "$size"
        done
    done
    printf 'website/public/favicon.png 32 32\n'
    printf 'website/public/favicon-16.png 16 16\n'
    printf 'website/public/apple-touch-icon.png 180 180\n'
)

# The Lab colors: navy and blue are counted only where the icon is opaque,
# since the transparent gutter reads as (0, 0, 0, 0).
xcrun swift - "$BRAND/AppIcon.iconset/icon_512x512@2x.png" <<'SWIFT' \
    || fail "the 1024 app icon lost its gutter, its Lab colors, or restored a retired palette"
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
    var nearWhite = 0
    var navy = 0
    var blue = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let r = Int(pixels[offset])
        let g = Int(pixels[offset + 1])
        let b = Int(pixels[offset + 2])
        let a = Int(pixels[offset + 3])
        if a < 16 { transparent += 1 }
        if g > 170 && g > r * 2 && g > b + 25 { turquoise += 1 }
        if r >= 225 && g >= 225 && b >= 225 { nearWhite += 1 }
        if a >= 200 && r < 60 && g < 70 && b < 110 { navy += 1 }
        if a >= 200 && b > 200 && r < 100 { blue += 1 }
    }
    let count = Double(width * height)
    guard Double(transparent) / count > 0.02 else { exit(4) }
    guard Double(turquoise) / count < 0.002 else { exit(5) }
    guard Double(nearWhite) / count >= 0.35 else { exit(6) }
    guard (0.05...0.15).contains(Double(navy) / count) else { exit(7) }
    guard Double(blue) / count >= 0.003 else { exit(8) }
}
SWIFT

# At 16 to 32 px the h, the i and the dot stay three shapes: below the arch
# the h's two stems and the i are separate, with a clear column between the
# h and the i, and a clear row between the dot and the i.
xcrun swift - \
    "$BRAND/AppIcon.iconset/icon_16x16.png" \
    "$BRAND/AppIcon.iconset/icon_32x32.png" \
    "$REPO_ROOT/extensions/chromium/icons/toolbar-16.png" \
    "$REPO_ROOT/extensions/chromium/icons/toolbar-19.png" \
    "$REPO_ROOT/extensions/chromium/icons/toolbar-32.png" \
    "$REPO_ROOT/website/public/favicon-16.png" \
    "$REPO_ROOT/website/public/favicon.png" <<'SWIFT' \
    || fail "a small icon merges the h, the i or the dot"
import CoreGraphics
import Foundation
import ImageIO

func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

for path in CommandLine.arguments.dropFirst() {
    let name = URL(fileURLWithPath: path).lastPathComponent
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { refuse("\(name) cannot be read") }
    let width = image.width, height = image.height
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { refuse("\(name) cannot be read") }
    let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }
    func isBlue(_ x: Int, _ y: Int) -> Bool {
        let p = pixel(x, y)
        return p.a >= 250 && p.b > 150 && p.b > p.r + 60
    }
    func isInk(_ x: Int, _ y: Int) -> Bool {
        let p = pixel(x, y)
        return p.a >= 250 && !isBlue(x, y) && (p.r + p.g + p.b) / 3 < 200
    }
    func isClear(_ x: Int, _ y: Int) -> Bool {
        let p = pixel(x, y)
        return p.a >= 250 && !isBlue(x, y) && (p.r + p.g + p.b) / 3 >= 215
    }

    let inkRows = (0..<height).filter { y in (0..<width).contains { isInk($0, y) } }
    guard let top = inkRows.first, let bottom = inkRows.last else { refuse("\(name) has no letters") }
    let lower = (top + (bottom - top) * 65 / 100)...bottom
    var runs: [ClosedRange<Int>] = []
    for x in 0..<width where lower.contains(where: { isInk(x, $0) }) {
        if let last = runs.last, last.upperBound == x - 1 {
            runs[runs.count - 1] = last.lowerBound...x
        } else {
            runs.append(x...x)
        }
    }
    guard runs.count == 3 else { refuse("\(name): expected the h's two stems and the i, found \(runs.count) shapes") }
    let between = (runs[1].upperBound + 1)..<runs[2].lowerBound
    guard between.contains(where: { x in lower.allSatisfy { isClear(x, $0) } }) else {
        refuse("\(name): no clear column between the h and the i")
    }
    let blueRows = (0..<height).filter { y in (0..<width).contains { isBlue($0, y) } }
    guard let dotBottom = blueRows.last else { refuse("\(name) has no blue dot") }
    guard let iTop = (0..<height).first(where: { y in runs[2].contains { isInk($0, y) } }),
          dotBottom + 1 < iTop,
          ((dotBottom + 1)..<iTop).contains(where: { y in runs[2].allSatisfy { isClear($0, y) } })
    else { refuse("\(name): the dot touches the i") }
}
SWIFT

python3 - "$REPO_ROOT" <<'PY' || fail "an icon PNG carries metadata or the touch icon is not opaque"
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1])
private = {b"eXIf", b"tEXt", b"iTXt", b"zTXt"}
icons = sorted((root / "assets/branding/AppIcon.iconset").glob("*.png"))
icons += sorted((root / "extensions").glob("*/icons/*.png"))
icons += [root / "website/public" / name for name in ("icon.png", "favicon.png", "favicon-16.png", "apple-touch-icon.png")]
for path in icons:
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a PNG"
    offset = 8
    while offset < len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        assert kind not in private, f"{path.relative_to(root)} carries a {kind.decode()} chunk"
        offset += 12 + length
touch = (root / "website/public/apple-touch-icon.png").read_bytes()
assert touch[25] in (0, 2), "apple-touch-icon.png must be opaque; iOS fills transparency with black"
PY

cmp -s "$REPO_ROOT/website/public/icon.png" "$BRAND/AppIcon.iconset/icon_512x512@2x.png" \
    || fail "website/public/icon.png differs from the 1024 app icon"

for size in 16 19 32 38 48 72 96 128; do
    cmp "$REPO_ROOT/extensions/safari/icons/toolbar-$size.png" \
        "$REPO_ROOT/extensions/chromium/icons/toolbar-$size.png" \
        || fail "Safari and Chromium toolbar-$size.png differ"
done

"$SCRIPT_DIR/generate-brand-assets.sh" --check
"$SCRIPT_DIR/test-screenshot-assets.sh"
printf 'PASS: product visual assets use the hi mark\n'
