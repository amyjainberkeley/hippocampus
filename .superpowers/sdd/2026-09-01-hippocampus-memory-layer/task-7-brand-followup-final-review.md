# Task 7 Brand Follow-up Final Review

Commits reviewed together:

- `c44e0566822c9e66ca5bee9ba9db9301cba6c198` (`fix: unify light brand assets`)
- `d02706b1ffbe99184f108ab189e9c87780b8f413` (`fix: complete light installer branding`)

Prior review: `task-7-brand-followup-review.md`

Scope: review only. Unrelated worktree changes were ignored. No production code or brand asset was edited.

## Verdict: FAIL

The two visible defects from the prior review are repaired in the current tree. The DMG volume icon is byte-identical to the canonical AppIcon, and the generated drag arrow now points from the app on the left toward Applications on the right. The required installer invariant is still not enforced, however: the build continues to trust an independently maintained manual copy of the icon and contains no equality or provenance check. That leaves the exact P1 stale-volume-icon regression able to return silently.

## Finding

### [P2] The installer does not enforce canonical volume-icon identity

The current files are correct:

- `assets/branding/AppIcon.icns`: SHA-256 `bfd23952e58d8f1aa78119a5b47185949270c20bfbc3cef8371e0e736a587991`
- `assets/installer/volume-icon.icns`: SHA-256 `bfd23952e58d8f1aa78119a5b47185949270c20bfbc3cef8371e0e736a587991`
- Both are 996,859 bytes and pass `cmp`.

But `scripts/build-installer.sh:483-486` still copies `assets/installer/volume-icon.icns` directly without comparing it to `assets/branding/AppIcon.icns` or deriving it from that canonical file. `scripts/README.md:93` explicitly describes the maintenance process as a manual copy. There is no test or preflight assertion covering this identity relationship.

This was part of the required fix in the prior review: replace the stale icon and add a direct equality or provenance check so the installer cannot silently regress to a second identity. The binary replacement landed; the guard did not.

Required fix: make `build-installer.sh` stage `assets/branding/AppIcon.icns` directly, or fail preflight unless the two files are byte-identical. Add a focused shell test that proves a mismatched secondary icon is rejected.

## Repaired Checks

### Volume icon

- The canonical AppIcon and shipping DMG volume icon pass byte-for-byte `cmp`.
- Both ICNS files extract successfully with `iconutil`.
- Extracted app and volume iconsets compare recursively with no differences.
- `build-installer.sh` currently stages this corrected file as `.VolumeIcon.icns` and applies the custom-icon attributes after mounting the DMG.
- `build-app.sh` independently stages the same canonical AppIcon as `Contents/Resources/AppIcon.icns`; `Info.plist` names `AppIcon` for both `CFBundleIconFile` and `CFBundleIconName`.

### Arrow and installer background

- `APP_POS=(340,460)` is left of `APPS_POS=(940,460)`.
- The shaft spans `x=415..865`.
- The arrowhead has a one-pixel apex at `(865,460)` and widens leftward to 21 pixels at `x=842`, proving a right-pointing direction.
- The committed background regenerates byte for byte in two independent runs.
- All three files hash to `56d70256d8f9a3127059e9a6be24e8ec25a9bdaeea06e70565aa17fde2ff308a`.
- The PNG is nonblank 1280x800 RGB with 89 distinct colors, no alpha, mean luminance 247.25/255, and zero exact retired `#7AFFC1` or `#0D0D0D` pixels.
- Visual rendering shows a light snow-to-white field, legible layered-memory watermark, two icon placement rings, and a cobalt arrow pointing from left to right.

### Brand sources and renders

- `hippocampus-icon.svg` renders as a nonblank, crisp compact layered-memory mark.
- `hippocampus-wordmark.svg` renders as a nonblank, legible dark system-sans wordmark on a light/transparent surface.
- The 512 px app icon renders as a nonblank light dimensional icon with the same layered-memory mark.
- `AppIcon.svg`, `AppIcon-template.svg`, `hippocampus-icon.svg`, and `hippocampus-wordmark.svg` all pass `xmllint`.
- `generate-background.py` passes Python bytecode compilation and direct execution.
- The app and installer shell scripts pass `bash -n`.
- The current shipping source paths contain no retired turquoise/mint or near-black field values. Repository-wide references outside current brand build paths are documentation, compatibility aliases, SF Symbols used as UI glyphs, or an old docs diagram; none is consumed by the current app/DMG brand asset pipeline.
- `git diff --check c44e056^..d02706b` passes.

## Exact Commands

```bash
git cat-file -t c44e056
git cat-file -t d02706b
git merge-base --is-ancestor c44e056 d02706b
git diff --check c44e056^..d02706b
git diff --quiet d02706b -- \
  assets/branding assets/installer scripts/build-installer.sh \
  apps/hippocampus/Resources/build-app.sh \
  apps/hippocampus/Resources/Info.plist

xmllint --noout assets/branding/AppIcon.svg
xmllint --noout assets/branding/AppIcon-template.svg
xmllint --noout assets/branding/hippocampus-icon.svg
xmllint --noout assets/branding/hippocampus-wordmark.svg
PYTHONPYCACHEPREFIX=/tmp/hippo-brand-final.../pycache \
  python3 -m py_compile assets/installer/generate-background.py
bash -n scripts/build-installer.sh
bash -n apps/hippocampus/Resources/build-app.sh

python3 assets/installer/generate-background.py \
  /tmp/hippo-brand-final.../background-a.png
python3 assets/installer/generate-background.py \
  /tmp/hippo-brand-final.../background-b.png
cmp /tmp/hippo-brand-final.../background-a.png \
  /tmp/hippo-brand-final.../background-b.png
cmp assets/installer/background.png \
  /tmp/hippo-brand-final.../background-a.png
shasum -a 256 assets/installer/background.png \
  /tmp/hippo-brand-final.../background-a.png \
  /tmp/hippo-brand-final.../background-b.png
sips -g pixelWidth -g pixelHeight -g format -g hasAlpha \
  assets/installer/background.png

cmp assets/branding/AppIcon.icns assets/installer/volume-icon.icns
shasum -a 256 \
  assets/branding/AppIcon.icns assets/installer/volume-icon.icns
stat -f '%N %z bytes' \
  assets/branding/AppIcon.icns assets/installer/volume-icon.icns
iconutil -c iconset assets/branding/AppIcon.icns \
  -o /tmp/hippo-brand-final.../app.iconset
iconutil -c iconset assets/installer/volume-icon.icns \
  -o /tmp/hippo-brand-final.../volume.iconset
diff -rq /tmp/hippo-brand-final.../app.iconset \
  /tmp/hippo-brand-final.../volume.iconset

qlmanage -t -s 512 -o /tmp/hippo-brand-final.../quicklook \
  assets/branding/hippocampus-icon.svg
qlmanage -t -s 840 -o /tmp/hippo-brand-final.../quicklook \
  assets/branding/hippocampus-wordmark.svg

rg -n -i \
  '#?7affc1|#?0d0d0d|turquoise|neon mint|head.?brain|brain.?head|seahorse|hippocampus glyph' \
  assets/branding assets/installer apps/hippocampus/Resources \
  scripts/build-installer.sh scripts/README.md

/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
  apps/hippocampus/Resources/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' \
  apps/hippocampus/Resources/Info.plist
```

The PNG statistics and arrow geometry were verified with a read-only Python standard-library parser that decoded the generated RGB PNG, counted colors and retired palette pixels, and checked the arrowhead width progression from its left base to its right apex.
