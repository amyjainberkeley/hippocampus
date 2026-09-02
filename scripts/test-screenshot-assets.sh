#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOTS="$REPO_ROOT/assets/screenshots"

required=(
    hero-cli.png
    hero-onboarding-trust-panel.png
    hero-onboarding-welcome.png
    hero-recall-ui.png
)

# Retired captures from the dark/tilted identity and pre-redesign Recall UI.
forbidden_hashes=(
    22619732574cf3f0d9c0efb69cac7445ae07ce2d23197be511c5805d5336dc59
    f1f2073cc420bfa47f7e5fc83277ebfb72fec121e56f8355bcdd344f1bc30a75
    583769a8cd66f68fc0902981e01a0de87ee73fe44a5e87c7b7698556c1359763
    761676cdbf59f2adbdc33b3752a009e934a1848859f0e255d52c893f880b9d79
)

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for name in "${required[@]}"; do
    [[ -f "$SCREENSHOTS/$name" ]] || fail "$name is missing"
done

[[ ! -e "$SCREENSHOTS/hero-hippocampus-menu.png" ]] \
    || fail "the retired, misleading menu screenshot must not return"

for image in "$SCREENSHOTS"/*.png; do
    digest="$(shasum -a 256 "$image" | awk '{print $1}')"
    for forbidden in "${forbidden_hashes[@]}"; do
        [[ "$digest" != "$forbidden" ]] \
            || fail "$(basename "$image") is a retired visual capture"
    done

    width="$(sips -g pixelWidth "$image" | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "$image" | awk '/pixelHeight:/ {print $2}')"
    [[ "$width" == 1280 && "$height" == 800 ]] \
        || fail "$(basename "$image") is ${width}x${height}, expected 1280x800"

    swift - "$image" <<'SWIFT' \
        || fail "$(basename "$image") is dominated by a near-black placeholder"
import CoreGraphics
import Foundation
import ImageIO

let path = CommandLine.arguments[1]
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { exit(2) }

let width = 64
let height = 40
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
context.interpolationQuality = .low
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

var nearBlack = 0
var retiredTurquoise = 0
var luminanceTotal = 0.0
for offset in stride(from: 0, to: pixels.count, by: 4) {
    let red = Double(pixels[offset])
    let green = Double(pixels[offset + 1])
    let blue = Double(pixels[offset + 2])
    let luminance = 0.2126 * Double(pixels[offset])
        + 0.7152 * Double(pixels[offset + 1])
        + 0.0722 * Double(pixels[offset + 2])
    luminanceTotal += luminance
    if luminance < 35 { nearBlack += 1 }
    if green > 160, green > red * 1.35, green > blue * 1.12 {
        retiredTurquoise += 1
    }
}
let count = width * height
let darkRatio = Double(nearBlack) / Double(count)
let average = luminanceTotal / Double(count)
let turquoiseRatio = Double(retiredTurquoise) / Double(count)
guard darkRatio < 0.65, average > 100, turquoiseRatio < 0.002 else { exit(4) }
SWIFT
done

xcrun swift - \
    "$SCREENSHOTS/hero-onboarding-welcome.png" "Your memory, on your Mac" \
    "$SCREENSHOTS/hero-onboarding-trust-panel.png" "Built for trust" \
    "$SCREENSHOTS/hero-recall-ui.png" "Latest memory" \
    "$SCREENSHOTS/hero-cli.png" "Launch qualified: false" \
    "$SCREENSHOTS/hero-cli.png" "false positives" <<'SWIFT' \
    || fail "exact product captures do not contain their current UI anchors"
import AppKit
import Foundation
import Vision

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count.isMultiple(of: 2) else { exit(2) }

for offset in stride(from: 0, to: arguments.count, by: 2) {
    let path = arguments[offset]
    let expected = arguments[offset + 1]
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { exit(3) }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
    guard text.localizedCaseInsensitiveContains(expected) else { exit(4) }
    if path.hasSuffix("hero-cli.png"),
       text.localizedCaseInsensitiveContains("all unanswerable cases still returned a result") {
        exit(5)
    }
}
SWIFT

rg -Fq 'Launch qualified: {str(scorecard['"'"'launch_qualified'"'"']).lower()}' \
    "$REPO_ROOT/scripts/render-cli-screenshot.py" \
    || fail "CLI renderer must preserve the benchmark launch-qualified field"
rg -Fq 'explicit-value veto is not relation-grounded' \
    "$REPO_ROOT/scripts/render-cli-screenshot.py" \
    || fail "CLI renderer must preserve the remaining evidence-policy gap"

printf 'PASS: screenshot assets are 1280x800 and light-surface dominated\n'
