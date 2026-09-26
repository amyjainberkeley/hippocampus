# Hippocampus Branding Assets

External product name: **Hippocampus**. Engineering codename: **MCI**.

## Source Of Truth

| File | Purpose |
|---|---|
| `AppIcon.svg` | Canonical app icon: a simple brain mark on one light surface. |
| `AppIcon-template.svg` | Monochrome, transparent menu-bar version of the same brain mark. |
| `AppIcon.iconset/` | macOS app-icon PNGs from 16 through 1024 px. |
| `AppIcon.icns` | Compiled Finder, Dock, Launchpad, Cmd-Tab, DMG, and Gatekeeper icon. |
| `hippocampus-icon.svg` | The same brain mark without an app-icon background. |
| `hippocampus-wordmark.svg` | Text-only product wordmark using the Apple system sans stack. |
| `statusbar-icon*.png` | 22/44/66 px menu-bar template images generated from `AppIcon-template.svg`. |
| `colors.json` | Canonical adaptive product and semantic color tokens. |

The Dock, menu bar, browser extensions and installer share one mark. Two solid
lobes and four short openings suggest a brain without an anatomical drawing.
The compact and menu-bar versions have transparent openings; macOS tints the
menu-bar template. The nested H tiles, black-and-mint artwork and oversized
installer watermark are retired.

## Palette

Light mode is the primary presentation:

- Snow canvas: `#F7F8FA`
- Clear surface: `#FFFFFF`
- Ink: `#1D1D1F`
- Graphite: `#6E6E73`
- Cobalt action: `#0A66D8`
- Coral change marker: `#C7473A`

Dark mode is adaptive support, not the brand's default backdrop. Cobalt marks
actions, coral marks changes or attention, and neutral grays carry structure.
Do not restore neon mint as a field color or use a near-black background as the
default product surface.

## Design Intent

Recognizable at Dock and menu-bar sizes, with no nested frames, lettering or
decorative wallpaper. All three SVGs use identical geometry. The paths are
original project assets, not traced from Apple's symbols or another product.

## Regenerating Assets

From the repository root, with `rsvg-convert` and macOS `iconutil` available:

```bash
ICONSET=assets/branding/AppIcon.iconset
SVG=assets/branding/AppIcon.svg
mkdir -p "$ICONSET"
rsvg-convert -w 16   -h 16   "$SVG" -o "$ICONSET/icon_16x16.png"
rsvg-convert -w 32   -h 32   "$SVG" -o "$ICONSET/icon_16x16@2x.png"
rsvg-convert -w 32   -h 32   "$SVG" -o "$ICONSET/icon_32x32.png"
rsvg-convert -w 64   -h 64   "$SVG" -o "$ICONSET/icon_32x32@2x.png"
rsvg-convert -w 128  -h 128  "$SVG" -o "$ICONSET/icon_128x128.png"
rsvg-convert -w 256  -h 256  "$SVG" -o "$ICONSET/icon_128x128@2x.png"
rsvg-convert -w 256  -h 256  "$SVG" -o "$ICONSET/icon_256x256.png"
rsvg-convert -w 512  -h 512  "$SVG" -o "$ICONSET/icon_256x256@2x.png"
rsvg-convert -w 512  -h 512  "$SVG" -o "$ICONSET/icon_512x512.png"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o assets/branding/AppIcon.icns
```

Menu-bar images:

```bash
SVG=assets/branding/AppIcon-template.svg
rsvg-convert -w 22 -h 22 "$SVG" -o assets/branding/statusbar-icon.png
rsvg-convert -w 44 -h 44 "$SVG" -o assets/branding/statusbar-icon@2x.png
rsvg-convert -w 66 -h 66 "$SVG" -o assets/branding/statusbar-icon@3x.png
```

After generating the iconset, copy `AppIcon.icns` to
`assets/installer/volume-icon.icns` and run
`python3 scripts/generate-extension-toolbar-icons.py` (requires Pillow).
For environments with the bundled Node runtime, Sharp can render the same SVG
sources to these exact pixel sizes instead of `rsvg-convert`.

The menu-bar image is loaded as an `NSImage` template so macOS supplies the
correct foreground tint in light and dark menu bars. `CFBundleIconFile` points
to the bundled `AppIcon.icns` for the app icon.

## Verification

Before release:

```bash
sips -g pixelWidth -g pixelHeight \
  assets/branding/AppIcon.iconset/icon_512x512@2x.png
iconutil -c iconset assets/branding/AppIcon.icns -o /tmp/Hippocampus.iconset
python3 assets/installer/generate-background.py
```

Check the 16 px icon, menu-bar image, full Dock icon, and generated installer
background on both light and dark desktops. The small sizes must remain legible
without depending on color.
