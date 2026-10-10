# Hippocampus Branding Assets

External product name: **Hippocampus**. Engineering codename: **MCI**.

## Source Of Truth

| File | Purpose |
|---|---|
| `AppIcon.svg` | Canonical app icon: the curl mark on a graphite tile. |
| `AppIcon-template.svg` | Monochrome, transparent menu-bar version of the same mark. |
| `AppIcon.iconset/` | macOS app-icon PNGs from 16 through 1024 px. |
| `AppIcon.icns` | Compiled Finder, Dock, Launchpad, Cmd-Tab, DMG, and Gatekeeper icon. |
| `hippocampus-icon.svg` | The same mark without the tile, for light backgrounds. |
| `hippocampus-wordmark.svg` | Text-only product wordmark using the Apple system sans stack. |
| `statusbar-icon*.png` | 22/44/66 px menu-bar template images generated from `AppIcon-template.svg`. |
| `colors.json` | Canonical adaptive product and semantic color tokens. |

The Dock, menu bar, browser extensions and installer share one mark: a
golden-ratio curl (the seahorse shape the hippocampus is named for) closing on
a dot for *now*. Memory gathers toward the present moment. The curl is built
from quarter-circle arcs whose radii shrink by the golden ratio, so it stays
even at every size. In single-colour versions the curl stops short of the dot,
so the dot reads as its own point in the menu bar. The brain mark, the nested
H tiles and the black-and-mint artwork are retired.

## Palette

- Icon tile: graphite `#2A2D35` to `#0B0C10`, a quiet dark surface like the
  Mac's own pro tools, so the mark carries the colour.
- Curl: `#9CC3FF` to `#2E6BFF`; dot `#FFFFFF`.

Product surfaces stay adaptive and light-first:

- Snow canvas: `#F7F8FA`
- Clear surface: `#FFFFFF`
- Ink: `#1D1D1F`
- Graphite: `#6E6E73`
- Cobalt action: `#0A66D8`
- Coral change marker: `#C7473A`

Cobalt marks actions, coral marks changes or attention, and neutral grays carry
structure. Do not restore neon mint.

## Design Intent

Recognizable at Dock and menu-bar sizes, with no lettering or decorative
wallpaper. All three SVGs share the `curl` path and the `now` dot exactly; only
the tile and the colours differ. The geometry is original to this project.

## Regenerating Assets

The SVGs are the source of truth. Rasterize them on a transparent background
with any SVG renderer that supports filters and masks; the shipped PNGs were
rendered by headless Chrome at each exact size:

| Output | Source | Sizes (px) |
|---|---|---|
| `AppIcon.iconset/icon_NxN[@2x].png` | `AppIcon.svg` | 16, 32, 32, 64, 128, 256, 256, 512, 512, 1024 |
| `statusbar-icon[@2x\|@3x].png` | `AppIcon-template.svg` | 22, 44, 66 |

Then:

```bash
iconutil -c icns assets/branding/AppIcon.iconset -o assets/branding/AppIcon.icns
cp assets/branding/AppIcon.icns assets/installer/volume-icon.icns
python3 scripts/generate-extension-toolbar-icons.py   # needs Pillow
scripts/test-product-visual-assets.sh
```
