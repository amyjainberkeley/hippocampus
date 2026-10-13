# Hippocampus Branding Assets

External product name: **Hippocampus**. Engineering codename: **MCI**.

## The Mark

**hi**: a lowercase h and i side by side, navy on a white tile, with the dot of
the i in blue. The Dock, the menu bar, Ask, the browser extensions, the website
and the installer all show it.

In the menu bar the dot says what Hippocampus is doing:

| Picture | Means |
|---|---|
| hi, solid dot | Remembering |
| hi, hollow dot | Skipping this window |
| h and a dotless i, dimmed | Paused or off |
| h! | Needs you |

A solid dot means it is remembering. No solid dot means it is not.
`hi-states-light.svg` and `hi-states-dark.svg` show the four pictures with
their words.

## Source Of Truth

One file draws every version of the mark:
`apps/hippocampus/Sources/HippocampusKit/Brand/HiMarkGeometry.swift`. The app
draws the menu bar and Ask from it while running, and
`scripts/generate-brand-assets.sh` draws every file here from it.

| File | Purpose |
|---|---|
| `AppIcon.svg` | The app icon: the mark on its tile. |
| `AppIcon-template.svg` | The mark in one color, without the tile. |
| `hippocampus-icon.svg` | The mark in its colors, without the tile, for light backgrounds. |
| `hi-states-light.svg`, `hi-states-dark.svg` | The four menu-bar pictures and their words. |
| `AppIcon.iconset/` | App icon PNGs from 16 to 1024 px. |
| `AppIcon.icns` | The Finder, Dock, Launchpad, ⌘-Tab, DMG and Gatekeeper icon. |
| `hippocampus-wordmark.svg` | Text-only wordmark in the Apple system sans. |
| `colors.json` | Product and semantic color tokens. |

## Colors

- Tile: `#FFFFFF` at the top to `#E9EEF6` at the bottom.
- Letters: `#0F1B3D`.
- Dot: `#2F6BFF`.

Product surfaces stay adaptive and light-first:

- Snow canvas: `#F7F8FA`
- Clear surface: `#FFFFFF`
- Ink: `#1D1D1F`
- Graphite: `#6E6E73`
- Cobalt action: `#0A66D8`
- Coral change marker: `#C7473A`

Cobalt marks actions, coral marks changes or attention, and neutral grays carry
structure.

## Drawing

- **App icon:** Apple's 1024 grid, an 824 tile inside a 100 gutter with a soft
  shadow and a hairline edge. The mark spans 56% of the tile's width, with a
  faint shadow under the letters.
- **Small sizes:** stems, baseline and dot sit on whole pixels, and the letter
  shadow starts at 64 px. At 16 px the app icon's mark is slightly larger, so
  the h, the i and the dot stay three shapes.
- **Browser toolbar icons and the favicon:** the tile fills the canvas, with no
  gutter and no tile shadow.
- **Touch icon:** an opaque square; iOS rounds the corners.
- **Menu bar:** four single-color templates at 1x, 2x and 3x, which macOS tints
  for light and dark menu bars.

## Regenerating Assets

```bash
scripts/generate-brand-assets.sh          # every SVG and PNG, AppIcon.icns, the installer's volume icon and website/public/icon.png
scripts/generate-brand-assets.sh --check  # fails if the SVGs no longer match the geometry
scripts/test-product-visual-assets.sh
```

The generator draws the PNGs with Core Graphics. PNG bytes can differ between
macOS versions, so `--check` compares only the SVGs.
