# Task 7 Brand Follow-up Final Review R2

Commits reviewed together:

- `c44e0566822c9e66ca5bee9ba9db9301cba6c198`
- `d02706b1ffbe99184f108ab189e9c87780b8f413`
- `506276c`

Prior reports:

- `task-7-brand-followup-review.md`
- `task-7-brand-followup-final-review.md`

Scope: fresh review only. Unrelated Task 2 and Task 5 worktree changes were ignored. No production file or brand asset was edited.

## Verdict: PASS

No blocking findings remain in the requested brand follow-up scope.

## Evidence

- The app icon, compact mark, wordmark, and installer background consistently use the light layered-memory identity. Fresh Quick Look renders were nonblank, legible, and free of the retired turquoise/black head-brain artwork.
- `assets/branding/AppIcon.icns` and `assets/installer/volume-icon.icns` are byte-identical. Both SHA-256 hashes are `bfd23952e58d8f1aa78119a5b47185949270c20bfbc3cef8371e0e736a587991`, both extract with `iconutil`, and the extracted iconsets compare without differences.
- `scripts/build-installer.sh --verify-assets` exits successfully for the committed files and runs the identity check before installer preflight or packaging. A mismatch returns nonzero with a specific repair instruction.
- The DMG stages `assets/branding/AppIcon.icns` directly as `.VolumeIcon.icns`; the verified installer mirror is no longer the shipping source.
- `scripts/test-installer-brand-assets.sh` reports `2 passed, 0 failed`: matching icons are accepted, while a deliberately corrupted mirror is rejected with the expected diagnostic.
- The committed background regenerates byte for byte in two independent runs. It is a nonblank 1280x800 RGB image with mean luminance 247.29/255, 89 distinct colors, and zero exact retired `#7AFFC1` or `#0D0D0D` pixels.
- Pixel geometry confirms a right-pointing arrow: the left base at `x=842` is 21 pixels high and narrows to a 3-pixel shaft/tip at `x=865`, with the app at `x=340` and Applications at `x=940`.
- All four SVG brand sources parse with `xmllint`; both shell scripts pass `bash -n`; `generate-background.py` passes bytecode compilation; `git diff --check c44e056^..506276c` passes.
- Requested brand and installer paths are unchanged from `506276c`; unrelated dirty files remain outside this review.

## Focused Commands

```bash
./scripts/test-installer-brand-assets.sh
./scripts/build-installer.sh --verify-assets
cmp assets/branding/AppIcon.icns assets/installer/volume-icon.icns
shasum -a 256 assets/branding/AppIcon.icns assets/installer/volume-icon.icns
bash -n scripts/build-installer.sh
bash -n scripts/test-installer-brand-assets.sh
xmllint --noout assets/branding/AppIcon.svg assets/branding/AppIcon-template.svg \
  assets/branding/hippocampus-icon.svg assets/branding/hippocampus-wordmark.svg
python3 assets/installer/generate-background.py /tmp/.../background-a.png
python3 assets/installer/generate-background.py /tmp/.../background-b.png
cmp assets/installer/background.png /tmp/.../background-a.png
iconutil -c iconset assets/branding/AppIcon.icns -o /tmp/.../app.iconset
iconutil -c iconset assets/installer/volume-icon.icns -o /tmp/.../volume.iconset
diff -rq /tmp/.../app.iconset /tmp/.../volume.iconset
git diff --check c44e056^..506276c
```
