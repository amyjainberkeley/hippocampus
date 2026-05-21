# Hippocampus — Branding Assets

External product name: **Hippocampus**. Engineering codename: **MCI**.

## Contents

| File | Purpose |
|---|---|
| `hippocampus-wordmark.svg` | Text-only wordmark, brutalist mono weight. SVG source of truth. |
| `hippocampus-icon.svg` | Stylized hippocampus glyph. Single-color SVG source. |
| `statusbar-icon.png` / `@2x` / `@3x` | macOS menu-bar template icons (16/32/48 px, black on transparent). |
| `AppIcon.iconset/` | macOS app icon PNGs (16–1024 px, 1x+2x). Mint-on-dark. |
| `AppIcon.icns` | Compiled macOS icon bundle (from `iconutil`). |
| `colors.json` | Brand color tokens — backgrounds, foreground, mint accent, semantic colors. |

## Color palette

- **Background primary:** `#0D0D0D` (near-black)
- **Foreground primary:** `#E0E0E0` (warm white)
- **Accent (mint):** `#7AFFC1` — high contrast on dark, non-aggressive
- All pairs meet WCAG AA (4.5:1 minimum contrast).

## Regenerating assets

### Status-bar icons

The `statusbar-icon*.png` files are generated from `hippocampus-icon.svg`. To regenerate:

```bash
# Requires Python 3 + Pillow
python3 scripts/generate-branding-icons.py
# Or manually with rsvg-convert:
rsvg-convert -w 16 -h 16 hippocampus-icon.svg -o statusbar-icon.png
rsvg-convert -w 32 -h 32 hippocampus-icon.svg -o statusbar-icon@2x.png
rsvg-convert -w 48 -h 48 hippocampus-icon.svg -o statusbar-icon@3x.png
```

### macOS .icns

```bash
# From the AppIcon.iconset/ directory:
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

### Using from SwiftUI

```swift
// Menu-bar icon (template rendering)
Image(nsImage: NSImage(named: "statusbar-icon")!)
    .renderingMode(.template)

// App icon (set in Xcode asset catalog or Info.plist CFBundleIconFile)
```

### Using from Rust (`include_bytes!`)

```rust
// Embed the .icns for programmatic use
const APP_ICON: &[u8] = include_bytes!("../../assets/branding/AppIcon.icns");
```

## Design decisions

- **No logo art for v1.** Name-only wordmark. The hippocampus glyph is a simple silhouette placeholder; a proper logo design is a Phase 5+ deliverable.
- **Dark palette matches ADR-0017 onboarding context.** The app runs as a menu-bar agent; dark surfaces reduce visual intrusion.
- **Mint accent** chosen over blue (too corporate) or green (too environmental). Mint reads "fresh / alive / memory" and has excellent contrast on dark.
