#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOTS="$REPO_ROOT/assets/screenshots"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for image in "$SCREENSHOTS"/*.png; do
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
var luminanceTotal = 0.0
for offset in stride(from: 0, to: pixels.count, by: 4) {
    let luminance = 0.2126 * Double(pixels[offset])
        + 0.7152 * Double(pixels[offset + 1])
        + 0.0722 * Double(pixels[offset + 2])
    luminanceTotal += luminance
    if luminance < 35 { nearBlack += 1 }
}
let count = width * height
let darkRatio = Double(nearBlack) / Double(count)
let average = luminanceTotal / Double(count)
guard darkRatio < 0.65, average > 100 else { exit(4) }
SWIFT
done

printf 'PASS: screenshot assets are 1280x800 and light-surface dominated\n'
