# Hippocampus — Branding Assets

External product name: **Hippocampus**. Engineering codename: **MCI**.

## Contents

| File | Purpose |
|---|---|
| `AppIcon.svg` | **Canonical AppIcon source** — original head+brain glyph, full-color squircle on flat mint. Commissioned 2026-05-27 per PR #205. |
| `AppIcon-template.svg` | **Canonical menu-bar template source** — monochrome outline head+brain, designed for macOS status-item template rendering at 22pt. Tinted by the OS for light/dark menu bars. |
| `AppIcon.iconset/` | macOS app icon PNGs (16–1024 px, 1x+2x). Rendered from `AppIcon.svg` via the regenerate command below. |
| `AppIcon.icns` | Compiled macOS icon bundle (from `iconutil`). |
| `hippocampus-wordmark.svg` | Text-only wordmark, brutalist mono weight. SVG source of truth. |
| `hippocampus-icon.svg` | Stylized hippocampus (seahorse) glyph. Single-color SVG source. Used on the landing page; **not** the AppIcon. |
| `statusbar-icon.png` / `@2x` / `@3x` | macOS menu-bar template PNGs (22/44/66 px) rendered from `AppIcon-template.svg`. **Wired** into `MenuBarIcon` via `NSImage(named: "statusbar-icon")` with `isTemplate = true` — the OS tints the alpha mask for light/dark menu bars. Bundled into the .app by `apps/hippocampus/Resources/build-app.sh`. |
| `colors.json` | Brand color tokens — backgrounds, foreground, mint accent, semantic colors. |

## Color palette

- **Background primary:** `#0D0D0D` (near-black)
- **Foreground primary:** `#E0E0E0` (warm white)
- **Accent (mint):** `#7AFFC1` — high contrast on dark, non-aggressive
- All pairs meet WCAG AA (4.5:1 minimum contrast).

## AppIcon glyph (head + brain) — origin & originality attestation

The AppIcon depicts a left-facing human head in profile with an anatomical-cortex brain visible inside the cranium, in dark `#0D0D0D` on a flat brand-mint (`#7AFFC1`) macOS Big-Sur squircle.

**Origin:** authored 2026-05-27 by Director-Recording via the gstack `/design-shotgun` skill. Seven distinct variants (A–G) were generated, varied along profile direction (left/right facing), brain rendering style (anatomical / faceted / circuit / organic / line-art / negative-space / node-graph), and background treatment. Variant A — left-facing dark head on flat brand mint, anatomical cortex curves — was selected.

**Originality attestation (non-negotiable):**
- **Not derivative of Apple's SF Symbol `brain.head.profile`.** Different silhouette (rounder cranium, distinct chin/jaw geometry, larger nose protrusion), different brain rendering (anatomical sulci curves vs. SF Symbol's two sweeping lines), different aspect ratio. Authored from coordinate math; no tracing of any SF Symbol export.
- **No third-party assets.** No Noun Project, no Iconfinder, no The Sketchpad. The path data lives in this repo and is hand-written.
- **No diffusion / image-to-image.** No Midjourney, DALL-E, Imagen, FLUX, or any generative-image model touched any pixel of these files. SVG path coordinates were authored directly by the agent.

Why this matters: PR #205 escalated that the head+brain glyph the CEO loved in the menu bar was Apple's SF Symbol `brain.head.profile`, drawn by Apple and shipped in the OS. Apple's SF Symbols license forbids using SF Symbols (or substantially-similar glyphs) as app icons, logos, or any trademark-bearing asset. Shipping a derivative on a notarized public DMG under Developer Program [REDACTED-TEAMID] would be a license violation. The asset in this directory is the original-art answer to that escalation.

**Do NOT replace these files with traced SF Symbol exports, AI-img2img derivatives of the SF Symbol, or any third-party brain/head icon.** If a future redesign is wanted, run `/design-shotgun` again and pick a fresh original.

## Regenerating assets

### AppIcon `.icns` from `AppIcon.svg`

```bash
# From the repo root, requires librsvg + macOS's iconutil (built-in).
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

Verify all 10 sizes are present + the 1024×1024 is real: `sips -g pixelWidth -g pixelHeight assets/branding/AppIcon.iconset/icon_512x512@2x.png`.

### Menu-bar template PNGs from `AppIcon-template.svg`

```bash
SVG=assets/branding/AppIcon-template.svg
rsvg-convert -w 22 -h 22 "$SVG" -o assets/branding/statusbar-icon.png
rsvg-convert -w 44 -h 44 "$SVG" -o assets/branding/statusbar-icon@2x.png
rsvg-convert -w 66 -h 66 "$SVG" -o assets/branding/statusbar-icon@3x.png
```

The template SVG is stroke-only by design: macOS templates use the alpha channel for tinting, so any opaque pixel gets tinted to the menu-bar foreground color. Fills inside the head would tint to the same color as the outline and erase the brain detail — strokes preserve it.

### Using from SwiftUI

```swift
// Menu-bar status item (template image — macOS tints automatically)
let img = NSImage(named: "statusbar-icon")!
img.isTemplate = true
statusItem.button?.image = img

// App icon: set via Info.plist CFBundleIconFile = "AppIcon"
// (the bundled AppIcon.icns), or via Asset Catalog.
```

### Using from Rust (`include_bytes!`)

```rust
// Embed the .icns for programmatic use (e.g., DMG volume icon copy).
const APP_ICON: &[u8] = include_bytes!("../../assets/branding/AppIcon.icns");
```

## Designer note

The choice is variant A: left-facing dark head on flat brand mint, with anatomical cortex curves inside the cranium in mint. Mint background does the brand-identity work (the rest of the visual system uses mint as the single accent, so the AppIcon at-a-glance reads "Hippocampus"). The head silhouette + cortex curves do the icon-content work (head + brain). The variant is intentionally NOT photoreal — calligraphic curves keep the icon human-warm rather than clinical-medical, while remaining unambiguously brain-shaped. The dark glyph on mint also gives the icon excellent contrast on both light and dark macOS Dock backgrounds. The menu-bar template uses the same head silhouette but stroke-only with four sulci hints, optimized for legibility at 22pt where the cortex curves would otherwise blur.

## Design decisions

- **AppIcon ships as canonical brand mark.** The head+brain glyph in `AppIcon.svg` is the AppIcon (Finder, Dock, Launchpad, Cmd-Tab, DMG window, Gatekeeper dialog). The seahorse `hippocampus-icon.svg` continues to ship on the landing page as a secondary mark — they are intentionally distinct (one is the *product*, the other is the *brand wordmark companion*).
- **Dark palette matches ADR-0017 onboarding context.** The app runs as a menu-bar agent; dark surfaces reduce visual intrusion.
- **Mint accent** chosen over blue (too corporate) or green (too environmental). Mint reads "fresh / alive / memory" and has excellent contrast on dark.
